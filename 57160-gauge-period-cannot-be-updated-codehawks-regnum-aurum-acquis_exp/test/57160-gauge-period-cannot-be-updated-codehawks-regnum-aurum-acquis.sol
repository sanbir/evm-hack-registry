// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC gauges — Codehawks, finding 57160 (Feb 2025)
    BaseGauge.updatePeriod is onlyController, and GaugeController never calls it.
    notifyRewardAmount still enforces the previous period's emission cap.
    After the period has ended, the next 1000 reward tokens cannot be accounted
    and stay in the gauge. A staker's claim returns 0. The control calls
    updatePeriod first, which clears `distributed`, and the staker receives 1000.
*/

contract RewardToken {
    string public symbol = "RAAC";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

error RewardCapExceeded();

contract BaseGauge {
    RewardToken public token;
    address public controller;
    uint256 public emissionCap;
    uint256 public distributed;
    uint256 public periodFinish;
    uint256 public accounted;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public paid;

    constructor(RewardToken _token, uint256 cap) {
        token = _token;
        emissionCap = cap;
        distributed = cap;
        periodFinish = 1;
    }

    function setController(address _controller) external {
        require(controller == address(0), "set");
        controller = _controller;
    }

    function stake(address user, uint256 amount) external {
        staked[user] += amount;
    }

    function updatePeriod() external {
        require(msg.sender == controller, "controller");
        if (block.timestamp >= periodFinish) {
            periodFinish = block.timestamp + 7 days;
            distributed = 0;
        }
    }

    function notifyRewardAmount(uint256 amount) external {
        require(msg.sender == controller, "controller");
        if (distributed + amount > emissionCap) revert RewardCapExceeded();
        distributed += amount;
        accounted += amount;
    }

    function claim(address user) external returns (uint256 owed) {
        if (staked[user] == 0) return 0;
        owed = accounted - paid[user];
        paid[user] = accounted;
        if (owed > 0) require(token.transfer(user, owed), "pay");
    }
}

contract GaugeController {
    BaseGauge public gauge;

    constructor(BaseGauge _gauge) {
        gauge = _gauge;
    }

    function distribute(uint256 amount) external {
        // @> VULN: GaugeController never calls updatePeriod, so an expired period still consumes the emission cap
        gauge.notifyRewardAmount(amount);
    }

    function distributeFixed(uint256 amount) external {
        gauge.updatePeriod();
        gauge.notifyRewardAmount(amount);
    }
}

contract Exploit {
    uint256 public constant EMISSION = 1000 ether;
    address public constant staker = address(0xB0B);

    RewardToken public token;
    BaseGauge public gauge;
    GaugeController public controller;
    bool public notifyReverted;
    uint256 public claimed;
    uint256 public stuck;

    constructor() {
        token = new RewardToken();
        gauge = new BaseGauge(token, EMISSION);
        controller = new GaugeController(gauge);
        gauge.setController(address(controller));
        gauge.stake(staker, 1 ether);
    }

    function run() external {
        token.mint(address(this), EMISSION);
        token.transfer(address(gauge), EMISSION);
        try controller.distribute(EMISSION) {
            notifyReverted = false;
        } catch {
            notifyReverted = true;
        }
        claimed = gauge.claim(staker);
        stuck = token.balanceOf(address(gauge));
        require(notifyReverted, "notify");
        require(gauge.distributed() == EMISSION, "cap");
        require(gauge.accounted() == 0, "unaccounted");
        require(claimed == 0, "claim");
        require(stuck == EMISSION, "stuck");
        require(token.balanceOf(staker) == 0, "staker");
    }
}
