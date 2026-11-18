// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Flayer — lister overpays used tax on Listings.cancelListings (Sherlock H-23, issue 705)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: createListings pays the lister `1 COL - prepaidTax`. cancelListings
    requires `1 COL - unusedTax` back. prepaidTax = unused + used, so the lister must
    pay the already-withheld used tax a second time. The blamed lines are verbatim. */

contract ColToken {
    string public constant symbol = "COL";
    uint8 public constant decimals = 18;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function denomination() external pure returns (uint8) {
        return 0;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[BURN] += amount;
    }
}

contract TaxCalculator {
    // Flat prepaid tax for this listing. Real calculator is a view over floor multiple and duration.
    function calculateTax(address, uint16, uint32) external pure returns (uint256) {
        return 0.2 ether;
    }
}

contract FeeSink {
    ColToken public immutable token;

    constructor(ColToken _token) {
        token = _token;
    }

    function depositFees(address, uint256, uint256 fees) external {
        token.transferFrom(msg.sender, address(this), fees);
    }
}

contract Locker {
    ColToken public immutable collection;
    TaxCalculator public immutable calculator;
    FeeSink public immutable sink;

    constructor(ColToken _collection, TaxCalculator _calculator, FeeSink _sink) {
        collection = _collection;
        calculator = _calculator;
        sink = _sink;
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function collectionToken(address) external view returns (ColToken) {
        return collection;
    }

    function taxCalculator() external view returns (TaxCalculator) {
        return calculator;
    }

    function implementation() external view returns (FeeSink) {
        return sink;
    }

    function withdrawToken(address, uint256, address) external {}
}

contract ProtectedListings {
    function createCheckpoint(address) external {}
}

contract Listings {
    uint32 public constant MIN_LIQUID_DURATION = 7 days;
    uint32 public constant MAX_LIQUID_DURATION = 180 days;
    uint32 public constant MIN_DUTCH_DURATION = 1 days;
    uint32 public constant MAX_DUTCH_DURATION = 7 days - 1;

    struct Listing {
        address payable owner;
        uint40 created;
        uint32 duration;
        uint16 floorMultiple;
    }

    enum ListingType {
        NONE,
        DUTCH,
        LIQUID
    }

    Locker public immutable locker;
    ProtectedListings public protectedListings;
    mapping(address => mapping(uint256 => Listing)) private _listings;
    mapping(address => uint256) public listingCount;
    uint256 public lastFees;
    uint256 public lastRefund;
    uint256 public lastRequired;

    error CallerIsNotOwner(address owner);
    error CannotCancelListingType();

    constructor(Locker _locker, ProtectedListings _protected) {
        locker = _locker;
        protectedListings = _protected;
    }

    modifier lockerNotPaused() {
        require(!locker.paused(), "paused");
        _;
    }

    // The listing as cancelListings sees it: created `elapsed` seconds ago, still inside a liquid term.
    function seedAgedListing(address collection, uint256 tokenId, address owner_, uint256 elapsed, uint32 duration_)
        external
    {
        Listing storage listing = _listings[collection][tokenId];
        listing.owner = payable(owner_);
        listing.created = uint40(block.timestamp - elapsed);
        listing.duration = duration_;
        listing.floorMultiple = 200;
        listingCount[collection] = 1;
    }

    function cancelListings(address _collection, uint256[] memory _tokenIds, bool _payTaxWithEscrow)
        public
        lockerNotPaused
    {
        uint256 fees;
        uint256 refund;

        for (uint256 i; i < _tokenIds.length; ++i) {
            uint256 _tokenId = _tokenIds[i];
            Listing memory listing = _listings[_collection][_tokenId];
            if (listing.owner != msg.sender) revert CallerIsNotOwner(listing.owner);
            ListingType listingType = getListingType(listing);
            if (listingType != ListingType.LIQUID) revert CannotCancelListingType();
            (uint256 _fees, uint256 _refund) = _resolveListingTax(listing, _collection, false);
            fees += _fees;
            refund += _refund;
            delete _listings[_collection][_tokenId];
            locker.withdrawToken(_collection, _tokenId, msg.sender);
        }

        ColToken collectionToken = locker.collectionToken(_collection);

        // Burn the ERC20 token that would have been given to the user when it was initially created
        uint256 requiredAmount = ((1 ether * _tokenIds.length) * 10 ** collectionToken.denomination()) - refund; // @> VULN: 1 COL minus unused tax. The lister was only paid 1 COL minus unused minus used, so the used tax is paid twice. FIX: subtract fees too.
        payTaxWithEscrow(address(collectionToken), requiredAmount, _payTaxWithEscrow);
        collectionToken.burn(requiredAmount + refund);

        if (fees != 0) {
            collectionToken.approve(address(locker.implementation()), fees);
            locker.implementation().depositFees(_collection, 0, fees);
        }

        unchecked {
            listingCount[_collection] -= _tokenIds.length;
        }
        protectedListings.createCheckpoint(_collection);
        lastFees = fees;
        lastRefund = refund;
        lastRequired = requiredAmount;
    }

    function getListingTaxRequired(Listing memory _listing, address _collection) public view returns (uint256 taxRequired_) {
        taxRequired_ = locker.taxCalculator().calculateTax(_collection, _listing.floorMultiple, _listing.duration);
        taxRequired_ *= 10 ** locker.collectionToken(_collection).denomination();
    }

    function payTaxWithEscrow(address _token, uint256 _taxRequired, bool) private {
        if (_taxRequired == 0) return;
        ColToken(_token).transferFrom(msg.sender, address(this), _taxRequired);
    }

    function _resolveListingTax(Listing memory _listing, address _collection, bool)
        private
        returns (uint256 fees_, uint256 refund_)
    {
        if (_listing.owner == address(0)) return (fees_, refund_);
        uint256 taxPaid = getListingTaxRequired(_listing, _collection);
        if (taxPaid == 0) return (fees_, refund_);
        if (block.timestamp < _listing.created + _listing.duration) {
            refund_ = (_listing.duration - (block.timestamp - _listing.created)) * taxPaid / _listing.duration;
        }
        unchecked {
            fees_ = (taxPaid > refund_) ? taxPaid - refund_ : 0;
        }
    }

    function getListingType(Listing memory _listing) public view returns (ListingType) {
        if (_listing.owner == address(0)) return ListingType.NONE;
        if (
            (_listing.duration >= MIN_DUTCH_DURATION && _listing.duration <= MAX_DUTCH_DURATION)
                || _listing.created + _listing.duration < block.timestamp
        ) {
            return ListingType.DUTCH;
        }
        return ListingType.LIQUID;
    }
}

contract Exploit {
    ColToken public token; // nonce 1
    TaxCalculator public tax; // nonce 2
    FeeSink public fees; // nonce 3
    Locker public locker; // nonce 4
    ProtectedListings public protectedListings; // nonce 5
    Listings public listings; // nonce 6

    constructor() {
        token = new ColToken();
        tax = new TaxCalculator();
        fees = new FeeSink(token);
        locker = new Locker(token, tax, fees);
        protectedListings = new ProtectedListings();
        listings = new Listings(locker, protectedListings);
    }

    function run() external {
        require(block.timestamp > 14 days, "clock");
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        listings.seedAgedListing(address(token), 1, address(this), 7 days, 14 days);
        // Prepaid tax withheld at create (0.2 COL) sits on Listings. Lister holds 0.8 proceeds + 0.1 pocket.
        token.mint(address(listings), 0.2 ether);
        token.mint(address(this), 0.9 ether);
        token.approve(address(listings), type(uint256).max);
        listings.cancelListings(address(token), ids, false);
        // Fair return is 0.8 COL. Bug pulls 0.9 COL and burns 1.0 COL. Used tax is 0.1 COL.
        require(listings.lastRequired() == 0.9 ether, "required");
        require(listings.lastFees() == 0.1 ether, "fees");
        require(listings.lastRefund() == 0.1 ether, "refund");
        require(token.balanceOf(address(this)) == 0, "pocket taken");
        require(token.balanceOf(0x000000000000000000000000000000000000dEaD) == 1 ether, "burned 1");
        require(token.balanceOf(address(fees)) == 0.1 ether, "fee sink");
    }

    function overpay() external pure returns (uint256) {
        return 0.1 ether;
    }
}
