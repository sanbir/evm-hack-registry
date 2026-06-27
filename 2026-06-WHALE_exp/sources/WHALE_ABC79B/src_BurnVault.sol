// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IWHALE} from "./interfaces/IWHALE.sol";

/**
 * @title BurnVault
 * @notice Queue-based vault that pays out active-burn rewards for the WHALE protocol (v8).
 *
 * Rules:
 *   1. `triggerReward`  — enqueue only. No payout. Controller-only.
 *   2. `processQueue`   — permissionless, batched payout, FIFO, up to `MAX_BATCH` entries.
 *   3. Reserve          — read live from `token.rawBalanceOf(this)` (no internal accounting).
 *   4. All-or-nothing   — a reward is paid only if the reserve fully covers the head amount.
 *
 * Reserve funding:
 *   - Main contract transfers sell-tax share (20%) into this vault.
 *   - Any WHALE accidentally sent here becomes reserve automatically.
 *
 * @dev The vault is a system-exempt address in WHALE. Since it never participates in claim,
 *      internal reads use `rawBalanceOf` (bypassing WHALE's `balanceOf` override).
 */
contract BurnVault is ReentrancyGuardTransient {
    // ============================================================
    // Errors
    // ============================================================

    error OnlyController();
    error AmountOverflow();
    error ZeroAddress();
    error IndexOutOfRange();
    error TransferFailed();

    // ============================================================
    // Events
    // ============================================================

    event RewardQueued(address indexed user, uint256 amount, uint128 queueIndex);
    /// @dev `queueIndex` matches the corresponding `RewardQueued` event so off-chain
    ///      indexers can correlate enqueue / payout pairs without relying on FIFO
    ///      assumptions or `(user, amount)` fuzzy matching.
    event RewardPaid(address indexed user, uint256 amount, uint128 queueIndex);

    // ============================================================
    // Constants
    // ============================================================

    /// @notice Max queue entries to pay in a single `processQueue` call.
    uint256 public constant MAX_BATCH = 15;

    // ============================================================
    // Immutables
    // ============================================================

    /// @notice WHALE token (uses IWHALE to expose `rawBalanceOf`).
    IWHALE public immutable token;

    /// @notice WHALE main contract — the only address allowed to enqueue.
    address public immutable controller;

    // ============================================================
    // Storage
    // ============================================================

    /// @dev Packs (user, amount) into one slot. `uint96` covers 7.9e28, well above 21M × 1e18.
    struct QueueEntry {
        address user;   // 20 bytes
        uint96 amount;  // 12 bytes
    }

    mapping(uint256 => QueueEntry) public queue;
    uint128 public queueHead;
    uint128 public queueTail;

    // ============================================================
    // Constructor (v6.8.4: full immutable, no init pattern)
    // ============================================================

    /// @notice Set token + controller as immutable. The cycle "WHALE needs vault_addr,
    ///         vault needs WHALE_addr" is broken off-chain via the registry pattern
    ///         (see `src/HashrateRegistry.sol`).
    /// @param _controller WHALE main contract address. Also serves as the token address
    ///                    (WHALE IS the token), so passed once.
    constructor(address _controller) {
        if (_controller == address(0)) revert ZeroAddress();
        token = IWHALE(_controller);
        controller = _controller;
    }

    // ============================================================
    // Modifiers
    // ============================================================

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    // ============================================================
    // External — Controller (enqueue only)
    // ============================================================

    /**
     * @notice Enqueue a burn-reward request. Payout happens in `processQueue`.
     * @dev Caller (WHALE main) is expected to have already computed the 1.3× amount (capped).
     * @param user   Burn initiator and reward recipient.
     * @param amount Reward in WHALE tokens.
     */
    function triggerReward(address user, uint256 amount) external onlyController {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        if (amount > type(uint96).max) revert AmountOverflow();

        uint128 tail = queueTail;
        queue[tail] = QueueEntry({user: user, amount: uint96(amount)});
        unchecked {
            queueTail = tail + 1;
        }
        emit RewardQueued(user, amount, tail);
    }

    // ============================================================
    // External — Public payout
    // ============================================================

    /**
     * @notice Pay out up to `MAX_BATCH` queued rewards FIFO.
     * @dev Permissionless; no caller incentive. Reserve is read live each call.
     * @return processed Number of entries actually paid out.
     */
    function processQueue() external nonReentrant returns (uint256 processed) {
        return _processQueueInternal();
    }

    // ============================================================
    // Internal
    // ============================================================

    function _processQueueInternal() internal returns (uint256 processed) {
        uint128 head = queueHead;
        uint128 tail = queueTail;
        if (head == tail) return 0; // empty queue — skip the external reserve read

        // Vault bypasses claim → raw balance is the authoritative reserve.
        uint256 currentBalance = token.rawBalanceOf(address(this));

        while (processed < MAX_BATCH && head < tail) {
            QueueEntry memory entry = queue[head];
            uint256 needed = uint256(entry.amount);

            // All-or-nothing: if reserve is short, stop and preserve FIFO order.
            if (currentBalance < needed) break;

            unchecked {
                currentBalance -= needed;
            }
            _transferToken(entry.user, needed);
            emit RewardPaid(entry.user, needed, head);

            // Entry intentionally NOT deleted: historical records remain queryable
            // via the public `queue(absoluteIndex)` getter, providing on-chain audit
            // trail without relying on event indexers. Storage cost: one slot per
            // historical entry, growing linearly with lifetime payouts.
            unchecked {
                ++head;
                ++processed;
            }
        }

        if (head != queueHead) queueHead = head;
    }

    function _transferToken(address to, uint256 amount) internal {
        if (!token.transfer(to, amount)) revert TransferFailed();
    }

    // ============================================================
    // Views
    // ============================================================

    /// @notice Current reserve (this contract's raw WHALE balance).
    function reserve() external view returns (uint256) {
        return token.rawBalanceOf(address(this));
    }

    /// @notice Number of unpaid entries in the queue.
    function queueLength() public view returns (uint256) {
        unchecked {
            return uint256(queueTail - queueHead);
        }
    }

    /// @notice Query queue entry by relative index (0 = head).
    function queueAt(uint256 index) external view returns (address user, uint256 amount) {
        if (index >= queueLength()) revert IndexOutOfRange();
        uint128 realIndex = queueHead + uint128(index);
        QueueEntry memory entry = queue[realIndex];
        return (entry.user, uint256(entry.amount));
    }

    /// @notice Paged queue read.
    function getQueue(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory users, uint256[] memory amounts)
    {
        uint256 length = queueLength();
        if (offset >= length || limit == 0) {
            return (new address[](0), new uint256[](0));
        }
        uint256 end = offset + limit;
        if (end > length) end = length;
        uint256 count = end - offset;

        users = new address[](count);
        amounts = new uint256[](count);

        uint128 start = queueHead + uint128(offset);
        for (uint256 i = 0; i < count;) {
            QueueEntry memory entry = queue[start + uint128(i)];
            users[i] = entry.user;
            amounts[i] = uint256(entry.amount);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Aggregate status view.
     * @return length         Queue length.
     * @return reserveAmount  Current reserve.
     * @return canProcess     True iff reserve covers head entry.
     * @return headUser       Head entry user.
     * @return headAmount     Head entry amount.
     */
    function getStatus()
        external
        view
        returns (uint256 length, uint256 reserveAmount, bool canProcess, address headUser, uint256 headAmount)
    {
        length = queueLength();
        reserveAmount = token.rawBalanceOf(address(this));
        if (length > 0) {
            QueueEntry memory head = queue[queueHead];
            headUser = head.user;
            headAmount = uint256(head.amount);
            canProcess = reserveAmount >= headAmount;
        }
    }

    /// @notice Sum of pending reward entries for a specific user (O(n); off-chain use).
    function pendingOf(address user) external view returns (uint256 total, uint256 count) {
        uint128 head = queueHead;
        uint128 tail = queueTail;
        for (uint128 i = head; i < tail;) {
            if (queue[i].user == user) {
                total += uint256(queue[i].amount);
                unchecked {
                    ++count;
                }
            }
            unchecked {
                ++i;
            }
        }
    }
}
