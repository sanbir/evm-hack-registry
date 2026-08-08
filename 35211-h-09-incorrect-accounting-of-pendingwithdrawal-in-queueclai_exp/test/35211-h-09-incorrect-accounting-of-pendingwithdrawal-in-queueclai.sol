// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Gondi — [H-09] Incorrect accounting of _pendingWithdrawal in queueClaiming
    flow (Code4rena 2024-04-gondi, finding #35211, reporter bin2chen).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: _updatePendingWithdrawalWithQueue assigns
      `_pendingWithdrawal[secondIdx] = pendingForQueue`
    instead of `+=`. When multiple older queues distribute into the same
    newer queue index, only the last distribution is kept — earlier
    contributions are erased after getTotalReceived is zeroed.

    Blamed line preserved verbatim from Pool.sol.
//////////////////////////////////////////////////////////////////////////*/

contract Pool {
    uint256 public constant PRINCIPAL_PRECISION = 1e18;

    /// @dev max queues is 2 → totalQueues = 3 (indices 0,1,2) in production;
    ///      here we use 3 queues for a clear multi-source loss.
    uint256 public getMaxTotalWithdrawalQueues = 2; // totalQueues = 3

    mapping(uint256 => uint256) public getTotalReceived;

    struct QueueAccounting {
        uint256 thisQueueFraction; // of PRINCIPAL_PRECISION
        uint256 netPoolFraction;
    }

    mapping(uint256 => QueueAccounting) public queueAccounting;

    /// @dev Public mirror of the final pendingWithdrawal array for asserts.
    uint256[] public lastPendingWithdrawal;
    uint256 public lostOnQueue; // shortfall on the harmed queue index

    function setQueueFraction(uint256 idx, uint256 thisQueueFraction) external {
        queueAccounting[idx] = QueueAccounting({thisQueueFraction: thisQueueFraction, netPoolFraction: 0});
    }

    function setTotalReceived(uint256 idx, uint256 amount) external {
        getTotalReceived[idx] = amount;
    }

    /// @dev Reduced from Pool._updatePendingWithdrawalWithQueue — bug intact.
    function _updatePendingWithdrawalWithQueue(
        uint256 _idx,
        uint256 _cachedPendingQueueIndex,
        uint256[] memory _pendingWithdrawal
    ) private returns (uint256[] memory) {
        uint256 totalReceived = getTotalReceived[_idx];
        uint256 totalQueues = getMaxTotalWithdrawalQueues + 1;
        /// @dev Nothing to be returned
        if (totalReceived == 0) {
            return _pendingWithdrawal;
        }
        getTotalReceived[_idx] = 0;

        /// @dev We go from idx to newer queues. Each getTotalReceived is the total
        /// returned from loans for that queue. All future queues/pool also have a piece of it.
        for (uint256 i; i < totalQueues;) {
            uint256 secondIdx = (_idx + i) % totalQueues;
            QueueAccounting memory qa = queueAccounting[secondIdx];
            if (qa.thisQueueFraction == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }
            /// @dev We looped around.
            if (secondIdx == _cachedPendingQueueIndex + 1) {
                break;
            }
            uint256 pendingForQueue = (totalReceived * qa.thisQueueFraction) / PRINCIPAL_PRECISION;
            totalReceived -= pendingForQueue;

            // @audit this should be _pendingWithdrawal[secondIdx] += pendingForQueue;
            // FIX: _pendingWithdrawal[secondIdx] += pendingForQueue;
            // @> VULN: assignment overwrites prior queues' contributions (need +=)
            _pendingWithdrawal[secondIdx] = pendingForQueue;
            unchecked {
                ++i;
            }
        }
        return _pendingWithdrawal;
    }

    /// @dev Reduced from Pool._queueClaimAll — iterates oldest→newest.
    function queueClaimAll(uint256 _cachedPendingQueueIndex) external returns (uint256[] memory pendingWithdrawal) {
        uint256 totalQueues = getMaxTotalWithdrawalQueues + 1;
        uint256 oldestQueueIdx = (_cachedPendingQueueIndex + 1) % totalQueues;
        pendingWithdrawal = new uint256[](totalQueues);
        for (uint256 i; i < pendingWithdrawal.length;) {
            uint256 idx = (oldestQueueIdx + i) % totalQueues;
            pendingWithdrawal = _updatePendingWithdrawalWithQueue(idx, _cachedPendingQueueIndex, pendingWithdrawal);
            unchecked {
                ++i;
            }
        }
        // persist for external asserts
        delete lastPendingWithdrawal;
        for (uint256 i; i < pendingWithdrawal.length; i++) {
            lastPendingWithdrawal.push(pendingWithdrawal[i]);
        }
    }

    function pendingAt(uint256 i) external view returns (uint256) {
        return lastPendingWithdrawal[i];
    }
}

/// @notice Two older queues both feed a newer queue. The second overwrite
///         erases the first contribution → lost claimable principal.
contract Exploit {
    uint256 public constant PRECISION = 1e18;
    // Queues: 0 (oldest received), 1 (mid received), 2 (newer claimant).
    // pendingQueueIndex = 2 means oldest is (2+1)%3 = 0.
    uint256 public constant PENDING_Q = 2;

    // Each older queue receives 100e18 from liquidations.
    uint256 public constant RECEIVED_0 = 100e18;
    uint256 public constant RECEIVED_1 = 100e18;

    // Fraction of each distribution allocated to queue 2 (the claimant): 50%.
    uint256 public constant FRAC_Q2 = PRECISION / 2; // 0.5e18

    Pool public pool;

    uint256 public expectedQ2; // if += were used
    uint256 public actualQ2; // after buggy =
    uint256 public lost; // expected - actual

    constructor() {
        pool = new Pool(); // nonce 1
    }

    function run() external {
        // Queue 2 is the "newer" queue that should accumulate from 0 and 1.
        // thisQueueFraction for idx==source means "this queue's own share of its
        // received" — for the reduction we only need secondIdx=2 to have a
        // non-zero fraction so both distributions allocate into it.
        //
        // When processing _idx=0: secondIdx walks 0,1,2. Only 2 has fraction →
        //   pendingForQueue = 100e18 * 50% = 50e18 → pending[2] = 50e18
        // When processing _idx=1: secondIdx walks 1,2,0. Only 2 has fraction →
        //   pendingForQueue = 100e18 * 50% = 50e18 → pending[2] = 50e18 (OVERWRITE)
        // Correct with +=: pending[2] = 100e18
        pool.setQueueFraction(2, FRAC_Q2);
        pool.setTotalReceived(0, RECEIVED_0);
        pool.setTotalReceived(1, RECEIVED_1);

        pool.queueClaimAll(PENDING_Q);

        actualQ2 = pool.pendingAt(2);
        // Both sources should have contributed 50e18 each.
        expectedQ2 = (RECEIVED_0 * FRAC_Q2) / PRECISION + (RECEIVED_1 * FRAC_Q2) / PRECISION; // 100e18
        require(expectedQ2 == 100e18, "expected math");
        require(actualQ2 == 50e18, "only last write kept");
        lost = expectedQ2 - actualQ2;

        // HARM: half of the claimable distribution for queue 2 is erased forever
        // (getTotalReceived already zeroed; cannot recover).
        require(lost == 50e18, "50e18 claimable funds lost");
        pool.lostOnQueue; // silence / leave public for tests via lost()
    }
}
