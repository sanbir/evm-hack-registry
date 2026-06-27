// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IWHALE} from "./interfaces/IWHALE.sol";

/**
 * @title RefVault
 * @notice Queue-based vault that pays out referral rewards for the WHALE protocol (v8).
 *
 * Structure is identical to BurnVault — the sole semantic difference is that `user` represents
 * the upline (referrer) rather than the actor. The WHALE main contract has already converted the
 * USDT-denominated referral amount into WHALE before enqueuing.
 */
contract RefVault is ReentrancyGuardTransient {
    // ============================================================
    // Errors
    // ============================================================

    error OnlyController();
    error ZeroAddress();
    error IndexOutOfRange();
    error TransferFailed();

    // ============================================================
    // Events
    // ============================================================

    event RewardQueued(address indexed referrer, uint256 amount, uint128 queueIndex);
    /// @dev `queueIndex` matches the corresponding `RewardQueued` event so off-chain
    ///      indexers can correlate enqueue / payout pairs without relying on FIFO
    ///      assumptions or `(referrer, amount)` fuzzy matching.
    event RewardPaid(address indexed referrer, uint256 amount, uint128 queueIndex);
    /// @dev Mirrors WHALE's prior `ReferralRewardTriggered` event. Emitted exactly once per
    ///      `downline` when their hashrate first crosses `VALID_INVITE_USDT`, signalling
    ///      that the upline's one-shot invite reward has been queued. Co-emitted from
    ///      `triggerReward` (folded into the existing reward-queueing path).
    event ReferralRewardTriggered(address indexed downline, address indexed referrer);

    // ============================================================
    // Constants
    // ============================================================

    uint256 public constant MAX_BATCH = 15;

    // ============================================================
    // Immutables
    // ============================================================

    IWHALE public immutable token;
    address public immutable controller;

    // ============================================================
    // Storage
    // ============================================================

    struct QueueEntry {
        address user;   // referrer
        uint96 amount;
    }

    mapping(uint256 => QueueEntry) public queue;
    uint128 public queueHead;
    uint128 public queueTail;

    // ============================================================
    // Constructor (v6.8.4: full immutable, no init pattern)
    // ============================================================

    /// @notice See BurnVault.constructor for cycle-breaking rationale.
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

    function triggerReward(address referrer, uint256 amount, address downline) external onlyController {
        if (referrer == address(0)) revert ZeroAddress();
        // ReferralRewardTriggered fires unconditionally (the threshold-crossing event
        // is real even when the queue-able reward is skipped due to dust or overflow).
        emit ReferralRewardTriggered(downline, referrer);
        // Silent skip on dust (amount=0) AND on uint96 overflow (extreme price collapse,
        // WHALE < ~2.5e-10 USDT). Clamping overflow to uint96.max would block the FIFO
        // queue head forever (RefVault's reserves can never reach 7.92e28 WHALE), so we
        // drop one extreme reward instead of bricking all subsequent payouts.
        if (amount == 0 || amount > type(uint96).max) return;

        uint128 tail = queueTail;
        queue[tail] = QueueEntry({user: referrer, amount: uint96(amount)});
        unchecked {
            queueTail = tail + 1;
        }
        emit RewardQueued(referrer, amount, tail);
    }

    // ============================================================
    // External — Public payout
    // ============================================================

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

        uint256 currentBalance = token.rawBalanceOf(address(this));

        while (processed < MAX_BATCH && head < tail) {
            QueueEntry memory entry = queue[head];
            uint256 needed = uint256(entry.amount);

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

    function reserve() external view returns (uint256) {
        return token.rawBalanceOf(address(this));
    }

    function queueLength() public view returns (uint256) {
        unchecked {
            return uint256(queueTail - queueHead);
        }
    }

    function queueAt(uint256 index) external view returns (address user, uint256 amount) {
        if (index >= queueLength()) revert IndexOutOfRange();
        uint128 realIndex = queueHead + uint128(index);
        QueueEntry memory entry = queue[realIndex];
        return (entry.user, uint256(entry.amount));
    }

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
