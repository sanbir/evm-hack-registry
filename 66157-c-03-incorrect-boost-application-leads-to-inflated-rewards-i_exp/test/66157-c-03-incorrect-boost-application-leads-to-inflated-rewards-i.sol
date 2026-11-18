// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum BaseGauge._calculatePendingRewards (Pashov, finding 66157).
    SYNTHETIC, cheatcode-free reduction.
    Root cause: the boost is a basis-point multiplier (20000 = 2x) but it
    replaces userShare instead of scaling it. Alice's 100 ether base becomes
    20000 wei, not 200 ether. The gauge keeps the rest. The control multiplies
    by the boost and divides by WEIGHT_PRECISION.
    The blamed assignment is preserved (@> VULN). */

contract MockERC20 {
    string public symbol = "RWD";
    uint8 public decimals = 18;
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

contract Sink {}

contract BaseGauge {
    uint256 public constant WEIGHT_PRECISION = 10_000;
    MockERC20 public reward;
    bool public immutable scaleBoost;
    mapping(address => uint256) public stake;
    uint256 public totalStake;
    uint256 public accrued;

    constructor(MockERC20 reward_, bool scaleBoost_) {
        reward = reward_;
        scaleBoost = scaleBoost_;
    }

    function seed(address user, uint256 userStake, uint256 rewardAccrued) external {
        stake[user] = userStake;
        totalStake = userStake;
        accrued = rewardAccrued;
    }

    function _applyBoost(address, uint256) internal pure returns (uint256) {
        return 20_000;
    }

    function _calculatePendingRewards(address user) public view returns (uint256 userShare) {
        userShare = stake[user] * accrued / totalStake;
        uint256 boost = _applyBoost(user, userShare);
        if (!scaleBoost) {
            // @> VULN: the basis-point boost replaces the token share
            userShare = boost > 0 ? boost : userShare;
        } else {
            userShare = boost > 0 ? (userShare * boost) / WEIGHT_PRECISION : userShare;
        }
    }

    function getReward(address user) external returns (uint256 paid) {
        paid = _calculatePendingRewards(user);
        reward.transfer(user, paid);
    }
}

contract Exploit {
    uint256 public constant STAKE = 1000 ether;
    uint256 public constant BASE = 100 ether;
    uint256 public constant FAIR = 200 ether;

    MockERC20 public reward; // nonce 1
    BaseGauge public gauge; // nonce 2
    BaseGauge public control; // nonce 3
    Sink public controlUser; // nonce 4

    uint256 public alicePaid;
    uint256 public controlPaid;

    constructor() {
        reward = new MockERC20();
        gauge = new BaseGauge(reward, false);
        control = new BaseGauge(reward, true);
        controlUser = new Sink();
        gauge.seed(address(this), STAKE, BASE);
        control.seed(address(controlUser), STAKE, BASE);
        reward.mint(address(gauge), FAIR);
        reward.mint(address(control), FAIR);
    }

    function run() external {
        uint256 preview = gauge._calculatePendingRewards(address(this));
        require(preview == 20_000, "preview was not the boost bps");
        alicePaid = gauge.getReward(address(this));
        require(alicePaid == 20_000, "alice was not paid 20000 wei");
        require(reward.balanceOf(address(this)) == 20_000, "alice balance");
        require(reward.balanceOf(address(gauge)) == FAIR - 20_000, "gauge did not keep the rest");

        controlPaid = control.getReward(address(controlUser));
        require(controlPaid == FAIR, "control did not pay 200 ether");
        require(reward.balanceOf(address(controlUser)) == FAIR, "control user");
        require(reward.balanceOf(address(control)) == 0, "control gauge not empty");
    }
}
