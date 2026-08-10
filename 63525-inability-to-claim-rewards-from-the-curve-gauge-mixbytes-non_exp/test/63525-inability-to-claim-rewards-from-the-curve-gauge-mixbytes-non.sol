// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Notional Finance (MixBytes) finding
// 63525: "Inability to Claim Rewards From the Curve Gauge".
//
// CurveConvex2Token._unstakeLpTokens() exits a pure-Curve-gauge position with
//   ICurveGauge(CURVE_GAUGE).withdraw(poolClaim);
// The Curve gauge withdraw is `def withdraw(_value, _claim_rewards: bool = False)`.
// Because the strategy's ICurveGauge interface only knows the single-argument
// entry point, the _claim_rewards flag defaults to False, so accrued CRV gauge
// rewards are NOT delivered on unstake. Unlike Convex strategies (wired to a
// ConvexRewardManager that later claims + distributes), a pure Curve strategy
// has NO reward-manager claim path, so those CRV rewards are stranded in the
// gauge forever and the effective yield is silently reduced.
//
// Harm asserted: after a full deposit -> accrue -> unstake cycle through the
// REAL (verbatim) _unstakeLpTokens, the strategy receives 0 CRV while the
// accrued 1000 CRV stays locked in the gauge with no strategy path to retrieve
// it. Negative control: an otherwise-identical fixed strategy that calls
// withdraw(poolClaim, true) delivers the full 1000 CRV — proving the missing
// flag is the exact cause. The undelivered/locked amount is recorded on a
// LOCKED-CRV marker minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double used for the Curve LP token, the CRV reward token,
///      and the LOCKED-CRV harm marker. Permissionless mint (test double only).
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful double for the external boundary: a Curve liquidity gauge.
//
// This mirrors the REAL Curve gauge Vyper semantics that make the finding real:
//   - Vyper `def withdraw(_value, _claim_rewards: bool = False)` compiles to TWO
//     distinct external selectors: withdraw(uint256) and withdraw(uint256,bool).
//     Modelled here as two overloads.
//   - The single-arg withdraw (the one the buggy strategy reaches) returns LP
//     but does NOT pay out accrued rewards (default _claim_rewards = False).
//   - The two-arg withdraw with _claim_rewards = true (and claim_rewards())
//     DOES pay out the accrued CRV.
// The gauge itself is correct per Curve spec; the bug is entirely in the
// strategy's failure to pass the flag / provide a claim path.
// ─────────────────────────────────────────────────────────────────────────────
contract CurveGauge {
    address public immutable lpToken;
    address public immutable crvToken;
    mapping(address => uint256) public balanceOf;       // staked LP per account
    mapping(address => uint256) public claimableReward; // accrued CRV per account

    constructor(address _lp, address _crv) {
        lpToken = _lp;
        crvToken = _crv;
    }

    function deposit(uint256 _value) external {
        MiniToken(lpToken).transferFrom(msg.sender, address(this), _value);
        balanceOf[msg.sender] += _value;
    }

    /// @dev Models CRV emission accruing to a staker over time (block/timestamp).
    function accrueReward(address user, uint256 amount) external {
        MiniToken(crvToken).mint(address(this), amount);
        claimableReward[user] += amount;
    }

    /// @dev Curve default-arg entry point #1: withdraw(uint256) => _claim_rewards = False.
    ///      Returns the LP but delivers NO rewards. This is the path the bug takes.
    function withdraw(uint256 _value) external {
        balanceOf[msg.sender] -= _value;
        MiniToken(lpToken).transfer(msg.sender, _value);
        // NOTE (faithful): _claim_rewards defaults to False -> rewards NOT claimed.
    }

    /// @dev Curve default-arg entry point #2: withdraw(uint256, bool).
    function withdraw(uint256 _value, bool _claim_rewards) external {
        balanceOf[msg.sender] -= _value;
        MiniToken(lpToken).transfer(msg.sender, _value);
        if (_claim_rewards) {
            uint256 r = claimableReward[msg.sender];
            claimableReward[msg.sender] = 0;
            MiniToken(crvToken).transfer(msg.sender, r);
        }
    }

    function claim_rewards() external {
        uint256 r = claimableReward[msg.sender];
        claimableReward[msg.sender] = 0;
        MiniToken(crvToken).transfer(msg.sender, r);
    }
}

// Interfaces exactly as the audited strategy declares them (single-arg withdraw).
interface ICurveGauge {
    function deposit(uint256 _value) external;
    function withdraw(uint256 _value) external;
    function claim_rewards() external;
}

interface IConvexBooster {
    function deposit(uint256 pid, uint256 amount, bool stake) external returns (bool);
}

interface IConvexRewardPool {
    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: CurveConvex2Token with the audited-commit _stakeLpTokens
// and _unstakeLpTokens inlined VERBATIM (notional-v4 @ 8dcb898,
// src/single-sided-lp/CurveConvex2Token.sol L324-L340). CONVEX_* are address(0),
// so both take the pure-Curve gauge branch — the configuration the finding is
// about (a Curve strategy with no reward manager).
// ─────────────────────────────────────────────────────────────────────────────
contract CurveConvex2Token {
    address internal immutable CURVE_GAUGE;
    address internal immutable CONVEX_REWARD_POOL;
    address internal immutable CONVEX_BOOSTER;
    uint256 internal immutable CONVEX_POOL_ID;
    address internal immutable CURVE_POOL_TOKEN;

    constructor(address gauge, address convexRewardPool, address poolToken) {
        CURVE_GAUGE = gauge;
        CONVEX_REWARD_POOL = convexRewardPool;
        CONVEX_BOOSTER = address(0);
        CONVEX_POOL_ID = 0;
        CURVE_POOL_TOKEN = poolToken;
        // Faithful to _initialApproveTokens: approve the gauge to pull LP.
        MiniToken(poolToken).approve(gauge, type(uint256).max);
    }

    /// @notice Public enter path used to drive the real staking lifecycle.
    function enter(uint256 lpTokens) external {
        _stakeLpTokens(lpTokens);
    }

    /// @notice The strategy's ONLY exit path (mirrors redeem/emergencyExit which
    ///         both funnel through _unstakeLpTokens in the audited source).
    function exit(uint256 poolClaim) external {
        _unstakeLpTokens(poolClaim);
    }

    // ---- VERBATIM from CurveConvex2Token.sol (audited commit) ----
    function _stakeLpTokens(uint256 lpTokens) internal {
        if (CONVEX_BOOSTER != address(0)) {
            bool success = IConvexBooster(CONVEX_BOOSTER).deposit(CONVEX_POOL_ID, lpTokens, true);
            require(success);
        } else {
            ICurveGauge(CURVE_GAUGE).deposit(lpTokens);
        }
    }

    function _unstakeLpTokens(uint256 poolClaim) internal {
        if (CONVEX_REWARD_POOL != address(0)) {
            bool success = IConvexRewardPool(CONVEX_REWARD_POOL).withdrawAndUnwrap(poolClaim, false);
            require(success);
        } else {
            ICurveGauge(CURVE_GAUGE).withdraw(poolClaim); // @> no _claim_rewards flag (defaults False) & no reward-manager claim path -> accrued CRV never delivered on unstake
        }
    }
    // ---- end verbatim ----
}

// Fixed interface variant knows the two-arg withdraw with the reward flag.
interface ICurveGaugeFixed {
    function deposit(uint256 _value) external;
    function withdraw(uint256 _value, bool _claim_rewards) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED control: identical strategy whose _unstakeLpTokens passes _claim_rewards
// = true, so the accrued CRV is delivered on exit. The ONLY delta vs the
// vulnerable contract is the missing flag on the withdraw call.
// ─────────────────────────────────────────────────────────────────────────────
contract CurveConvex2TokenFixed {
    address internal immutable CURVE_GAUGE;
    address internal immutable CONVEX_REWARD_POOL;
    address internal immutable CURVE_POOL_TOKEN;

    constructor(address gauge, address convexRewardPool, address poolToken) {
        CURVE_GAUGE = gauge;
        CONVEX_REWARD_POOL = convexRewardPool;
        CURVE_POOL_TOKEN = poolToken;
        MiniToken(poolToken).approve(gauge, type(uint256).max);
    }

    function enter(uint256 lpTokens) external {
        ICurveGaugeFixed(CURVE_GAUGE).deposit(lpTokens);
    }

    function exit(uint256 poolClaim) external {
        if (CONVEX_REWARD_POOL != address(0)) {
            IConvexRewardPool(CONVEX_REWARD_POOL).withdrawAndUnwrap(poolClaim, false);
        } else {
            ICurveGaugeFixed(CURVE_GAUGE).withdraw(poolClaim, true); // FIX: claim rewards on unstake
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: runs the real deposit -> accrue -> unstake cycle through the
// verbatim vulnerable strategy and proves accrued CRV is never delivered, while
// the fixed control delivers it in full. Harm magnitude recorded on the marker.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant STAKE = 100 ether;
    uint256 internal constant REWARD = 1000 ether; // accrued CRV gauge rewards

    // Deployed doubles / contracts.
    MiniToken internal lp;
    MiniToken internal crv;
    CurveGauge internal gaugeBuggy;
    CurveGauge internal gaugeFixed;
    CurveConvex2Token internal strategy;
    CurveConvex2TokenFixed internal strategyFixed;
    MiniToken internal marker;

    // Exposed results for the driver / Playground.
    uint256 public buggyStrategyCrv;   // CRV delivered to the buggy strategy on exit (== 0, the harm)
    uint256 public fixedStrategyCrv;   // CRV delivered to the fixed strategy on exit (== REWARD)
    uint256 public strandedInGauge;    // CRV left locked in the gauge after the buggy exit (== REWARD)
    uint256 public sinkMarkerBalance;  // LOCKED-CRV marker minted to SINK
    address public markerAddr;
    address public strategyAddr;       // the verbatim vulnerable contract
    address public gaugeAddr;
    address public crvAddr;

    constructor() {
        lp = new MiniToken("Curve.fi LP", "crvLP");                        // deploy 0
        crv = new MiniToken("Curve DAO Token", "CRV");                     // deploy 1
        gaugeBuggy = new CurveGauge(address(lp), address(crv));            // deploy 2
        gaugeFixed = new CurveGauge(address(lp), address(crv));            // deploy 3
        strategy = new CurveConvex2Token(address(gaugeBuggy), address(0), address(lp));       // deploy 4
        strategyFixed = new CurveConvex2TokenFixed(address(gaugeFixed), address(0), address(lp)); // deploy 5
        marker = new MiniToken("Locked CRV rewards", "LOCKED-CRV");        // deploy 6 (LAST)

        markerAddr = address(marker);
        strategyAddr = address(strategy);
        gaugeAddr = address(gaugeBuggy);
        crvAddr = address(crv);
    }

    function run() external payable {
        // ── BUGGY path: deposit -> gauge accrues CRV -> unstake via verbatim code ──
        lp.mint(address(strategy), STAKE);
        strategy.enter(STAKE);
        gaugeBuggy.accrueReward(address(strategy), REWARD);
        strategy.exit(STAKE); // ICurveGauge(CURVE_GAUGE).withdraw(poolClaim) — no reward flag

        buggyStrategyCrv = crv.balanceOf(address(strategy));   // == 0 : rewards NOT delivered
        strandedInGauge = crv.balanceOf(address(gaugeBuggy));  // == REWARD : locked, no claim path

        // ── FIXED control: identical flow, withdraw(poolClaim, true) delivers CRV ──
        lp.mint(address(strategyFixed), STAKE);
        strategyFixed.enter(STAKE);
        gaugeFixed.accrueReward(address(strategyFixed), REWARD);
        strategyFixed.exit(STAKE);

        fixedStrategyCrv = crv.balanceOf(address(strategyFixed)); // == REWARD : rewards delivered

        // ── Harm: the verbatim path strands the rewards; the fix delivers them. ──
        require(buggyStrategyCrv == 0, "buggy path delivered rewards");
        require(strandedInGauge == REWARD, "rewards not stranded in gauge");
        require(fixedStrategyCrv == REWARD, "fixed control failed to deliver");

        // Record the undelivered/locked CRV magnitude on the marker at the SINK.
        marker.mint(SINK, REWARD);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
