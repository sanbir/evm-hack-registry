// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/interfaces/IERC165.sol';
import '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import './TreasureNFTOracle.sol';

contract TreasureMarketplace is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes4 private constant INTERFACE_ID_ERC721 = 0x80ac58cd;
    bytes4 private constant INTERFACE_ID_ERC1155 = 0xd9b67a26;
    uint256 public constant BASIS_POINTS = 10000;

    address public oracle;
    address public paymentToken;

    uint256 public fee;
    address public feeReceipient;

    struct Listing {
        uint256 quantity;
        uint256 pricePerItem;
        uint256 expirationTime;
    }

    //  _nftAddress => _tokenId => _owner
    mapping(address => mapping(uint256 => mapping(address => Listing))) public listings;
    mapping(address => bool) public nftWhitelist;

    event UpdateFee(uint256 fee);
    event UpdateFeeRecipient(address feeRecipient);
    event UpdateOracle(address oracle);
    event UpdatePaymentToken(address paymentToken);

    event NftWhitelistAdd(address nft);
    event NftWhitelistRemove(address nft);

    event ItemListed(
        address seller,
        address nftAddress,
        uint256 tokenId,
        uint256 quantity,
        uint256 pricePerItem,
        uint256 expirationTime
    );

    event ItemUpdated(
        address seller,
        address nftAddress,
        uint256 tokenId,
        uint256 quantity,
        uint256 pricePerItem,
        uint256 expirationTime
    );

    event ItemSold(
        address seller,
        address buyer,
        address nftAddress,
        uint256 tokenId,
        uint256 quantity,
        uint256 pricePerItem
    );

    event ItemCanceled(address seller, address nftAddress, uint256 tokenId);

    modifier isListed(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) {
        Listing memory listing = listings[_nftAddress][_tokenId][_owner];
        require(listing.quantity > 0, "not listed item");
        _;
    }
    // isListed only protects against buying unlisted items. It does NOT validate the *requested purchase quantity*.
    // Attacker _quantity=0 still sees a positive stored quantity and passes.

    modifier notListed(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) {
        Listing memory listing = listings[_nftAddress][_tokenId][_owner];
        require(listing.quantity == 0, "already listed");
        _;
    }

    modifier validListing(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) {
        Listing memory listedItem = listings[_nftAddress][_tokenId][_owner];
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721 nft = IERC721(_nftAddress);
            require(nft.ownerOf(_tokenId) == _owner, "not owning item");
        } else if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)) {
            IERC1155 nft = IERC1155(_nftAddress);
            require(nft.balanceOf(_owner, _tokenId) >= listedItem.quantity, "not owning item");
        } else {
            revert("invalid nft address");
        }
        require(listedItem.expirationTime >= block.timestamp, "listing expired");
        _;
    }
    // validListing for ERC721 never consults the _quantity argument passed to buyItem.
    // The ownerOf snapshot + time check passes even when the subsequent buy will use _quantity=0.

    modifier onlyWhitelisted(address nft) {
        require(nftWhitelist[nft], "nft not whitelisted");
        _;
    }

    constructor(uint256 _fee, address _feeRecipient, address _oracle, address _paymentToken) {
        setFee(_fee);
        setFeeRecipient(_feeRecipient);
        setOracle(_oracle);
        setPaymentToken(_paymentToken);
    }

    function createListing(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _quantity,
        uint256 _pricePerItem,
        uint256 _expirationTime
    ) external notListed(_nftAddress, _tokenId, _msgSender()) onlyWhitelisted(_nftAddress) {
        if (_expirationTime == 0) _expirationTime = type(uint256).max;
        require(_expirationTime > block.timestamp, "invalid expiration time");
        require(_quantity > 0, "nothing to list");
        // NOTE: positive _quantity is *only* enforced on creation (and update has no such for ERC721 path).
        // The buy path lacks the symmetric require(_quantity > 0). This asymmetry is the root of the bypass.

        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721 nft = IERC721(_nftAddress);
            require(nft.ownerOf(_tokenId) == _msgSender(), "not owning item");
            require(nft.isApprovedForAll(_msgSender(), address(this)), "item not approved");
        } else if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)) {
            IERC1155 nft = IERC1155(_nftAddress);
            require(nft.balanceOf(_msgSender(), _tokenId) >= _quantity, "must hold enough nfts");
            require(nft.isApprovedForAll(_msgSender(), address(this)), "item not approved");
        } else {
            revert("invalid nft address");
        }

        listings[_nftAddress][_tokenId][_msgSender()] = Listing(
            _quantity,
            _pricePerItem,
            _expirationTime
        );

        emit ItemListed(
            _msgSender(),
            _nftAddress,
            _tokenId,
            _quantity,
            _pricePerItem,
            _expirationTime
        );
    }

    function updateListing(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _newQuantity,
        uint256 _newPricePerItem,
        uint256 _newExpirationTime
    ) external nonReentrant isListed(_nftAddress, _tokenId, _msgSender()) {
        require(_newExpirationTime > block.timestamp, "invalid expiration time");

        Listing storage listedItem = listings[_nftAddress][_tokenId][_msgSender()];
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721 nft = IERC721(_nftAddress);
            require(nft.ownerOf(_tokenId) == _msgSender(), "not owning item");
        } else if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)) {
            IERC1155 nft = IERC1155(_nftAddress);
            require(nft.balanceOf(_msgSender(), _tokenId) >= _newQuantity, "must hold enough nfts");
        } else {
            revert("invalid nft address");
        }

        listedItem.quantity = _newQuantity;
        listedItem.pricePerItem = _newPricePerItem;
        listedItem.expirationTime = _newExpirationTime;

        emit ItemUpdated(
            _msgSender(),
            _nftAddress,
            _tokenId,
            _newQuantity,
            _newPricePerItem,
            _newExpirationTime
        );
    }

    function cancelListing(address _nftAddress, uint256 _tokenId)
        external
        nonReentrant
        isListed(_nftAddress, _tokenId, _msgSender())
    {
        _cancelListing(_nftAddress, _tokenId, _msgSender());
    }

    function _cancelListing(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) internal {
        Listing memory listedItem = listings[_nftAddress][_tokenId][_owner];
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721 nft = IERC721(_nftAddress);
            require(nft.ownerOf(_tokenId) == _owner, "not owning item");
        } else if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)) {
            IERC1155 nft = IERC1155(_nftAddress);
            require(nft.balanceOf(_msgSender(), _tokenId) >= listedItem.quantity, "not owning item");
        } else {
            revert("invalid nft address");
        }

        delete (listings[_nftAddress][_tokenId][_owner]);
        emit ItemCanceled(_owner, _nftAddress, _tokenId);
    }

    function buyItem(
        address _nftAddress,
        uint256 _tokenId,
        address _owner,
        uint256 _quantity
    )
        external
        nonReentrant
        isListed(_nftAddress, _tokenId, _owner)
        validListing(_nftAddress, _tokenId, _owner)
    {
        require(_msgSender() != _owner, "Cannot buy your own item");

        Listing memory listedItem = listings[_nftAddress][_tokenId][_owner];
        require(listedItem.quantity >= _quantity, "not enough quantity");

        // VULNERABILITY: Zero-quantity acceptance + quantity-oblivious ERC721 path in buyItem
        // ROOT CAUSE DETAILED:
        // 1. isListed modifier (defined ~L79): `require(listing.quantity > 0, "not listed item");` -- guards *stored* quantity, not input _quantity.
        // 2. validListing ( ~L99 ): ERC721 case only does `require(nft.ownerOf(_tokenId) == _owner ...)` and expiration; _quantity never inspected.
        // 3. L240: `require(listedItem.quantity >= _quantity, "not enough quantity");`  -- mathematically true for _quantity=0.
        // 4. L244: `if (ERC721) { IERC721(...).safeTransferFrom(_owner, _msgSender(), _tokenId); }` -- tokenId transfer, _quantity param is dead for ERC721.
        //    (ERC1155 path passes _quantity to safeTransferFrom, but ERC721 semantics don't have "amount".)
        // 5. L249: `if (listedItem.quantity == _quantity) { delete } else { ...quantity -= _quantity; }` -- 1==0 false => -=0 (identity).
        // 6. L265: `_buyItem(listedItem.pricePerItem, _quantity, _owner);`
        // 7. In _buyItem (L273): `uint256 totalPrice = _pricePerItem * _quantity;` (0) then two safeTransferFrom of 0 amounts.
        //    Because the caller (buyer) did approve(0), the 0-value transferFroms from buyer succeed.
        // WHY THE GUARDS FAILED TO PREVENT: The positive-quantity requirement exists only on *listing creation* (L134: require(_quantity > 0)).
        //   No equivalent floor on the buy side. The buyer wrapper (public, permissionless) forwards the attacker's chosen _quantity verbatim.
        //   Arithmetic and comparisons in Solidity are well-defined at 0; no underflow/require was triggered.
        // Also note: the listing key includes the *seller* (_owner). Exploit must supply the current ownerOf result as that key (see PoC).
        // IMPACT: 100% of payment evaded for ERC721 purchases. Seller loses NFT ownership with 0 compensation. The marketplace
        //   emits ItemSold with quantity=0, reports a 0-total sale to oracle. Listing entry remains (now points to non-owner).
        //   Seller cannot easily clean it (cancelListing would fail ownerOf check inside _cancelListing).
        //   Systemic: breaks the economic invariant "listed item can only change hands for the listed price".
        // EXPLOIT STEPS (full end-to-end, marketplace view):
        // 1. (from buyer or direct) call buyItem(nft, tid, sellerAddr, 0, ... ) with sellerAddr = ownerOf(tid) at attack time.
        // 2. Modifiers pass (stored qty=1 >0; ownerOf matches; not expired).
        // 3. 1 >= 0 passes.
        // 4. safeTransferFrom moves SmolBrain#3557 (or any) to the buyer contract (or direct caller).
        // 5. No delete, quantity stays 1.
        // 6. 0 MAGIC moved in _buyItem (feeReceipient and seller get 0).
        // 7. Buyer (if used) forwards NFT to attacker via its on-receive holder + final safeTransferFrom.
        // 8. Attacker implements onERC721Received to accept. Done.
        // Transfer NFT to buyer
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721(_nftAddress).safeTransferFrom(_owner, _msgSender(), _tokenId);
        } else {
            IERC1155(_nftAddress).safeTransferFrom(_owner, _msgSender(), _tokenId, _quantity, bytes(""));
        }

        if (listedItem.quantity == _quantity) {
            delete (listings[_nftAddress][_tokenId][_owner]);
        } else {
            listings[_nftAddress][_tokenId][_owner].quantity -= _quantity;
        }

        emit ItemSold(
            _owner,
            _msgSender(),
            _nftAddress,
            _tokenId,
            _quantity,
            listedItem.pricePerItem
        );

        TreasureNFTOracle(oracle).reportSale(_nftAddress, _tokenId, paymentToken, listedItem.pricePerItem);
        _buyItem(listedItem.pricePerItem, _quantity, _owner);
    }

    function _buyItem(
        uint256 _pricePerItem,
        uint256 _quantity,
        address _owner
    ) internal {
        // VULNERABILITY (payment side): attacker-supplied _quantity reaches here with 0, zeroing the payment
        // totalPrice = _pricePerItem * _quantity;  (exact mul at L273, no saturation/guard)
        // feeAmount = total * fee / 10000;
        // Two safeTransferFrom(_msgSender(), ..., 0)  -- these are no-ops but succeed even with 0 allowance.
        // Note: _buyItem is internal, called only after the NFT has *already* been transferred (L244).
        // Order-of-operations means the economic check (payment) is after the state change (NFT move) -- classic.
        // No require(totalPrice > 0) anywhere in the payment path.
        // When _quantity=0 this is the step that actually "charges" the attacker nothing.
        uint256 totalPrice = _pricePerItem * _quantity;
        uint256 feeAmount = totalPrice * fee / BASIS_POINTS;
        IERC20(paymentToken).safeTransferFrom(_msgSender(), feeReceipient, feeAmount);
        IERC20(paymentToken).safeTransferFrom(_msgSender(), _owner, totalPrice - feeAmount);
    }

    // admin

    function setFee(uint256 _fee) public onlyOwner {
        require(_fee < BASIS_POINTS, "max fee");
        fee = _fee;
        emit UpdateFee(_fee);
    }

    function setFeeRecipient(address _feeRecipient) public onlyOwner {
        feeReceipient = _feeRecipient;
        emit UpdateFeeRecipient(_feeRecipient);
    }

    function setOracle(address _oracle) public onlyOwner {
        oracle = _oracle;
        emit UpdateOracle(_oracle);
    }

    function setPaymentToken(address _paymentToken) public onlyOwner {
        paymentToken = _paymentToken;
        emit UpdatePaymentToken(_paymentToken);
    }

    function setOracleOwner(address _newOwner) public onlyOwner {
        TreasureNFTOracle(oracle).transferOwnership(_newOwner);
    }

    function addToWhitelist(address _nft) external onlyOwner {
        require(!nftWhitelist[_nft], "nft already whitelisted");
        nftWhitelist[_nft] = true;
        emit NftWhitelistAdd(_nft);
    }

    function removeFromWhitelist(address _nft) external onlyOwner onlyWhitelisted(_nft) {
        nftWhitelist[_nft] = false;
        emit NftWhitelistRemove(_nft);
    }
}
