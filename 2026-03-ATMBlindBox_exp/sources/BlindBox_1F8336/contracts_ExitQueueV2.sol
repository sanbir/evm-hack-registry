// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IATMInterfaces.sol";

/**
 * @title ExitQueue — 1.5x出局 + 双队列FIFO + 加速插队
 * @notice 双向链表, 小额(<500U)/常规(≥500U), 50/50分配
 */
contract ExitQueue {
    using SafeERC20 for IERC20;

    address public immutable atmToken;
    address public immutable usdt;
    address public constant EXIT_HOLE = address(1);

    uint256 public constant MIN_EXIT_U = 10e18;
    uint256 public constant MAX_EXIT_U = 1000e18;
    uint256 public constant PAYOUT_MULT = 150; // 1.5x = 150/100
    uint256 public constant SPLIT_THRESHOLD = 500e18; // <500U small, ≥500U regular
    uint256 public constant MAX_ACCEL_U = 10e18; // max 10U acceleration (= 10 positions)
    uint256 public constant BATCH_SIZE = 10;

    // ═══════════ Linked List ═══════════
    struct Position {
        address user;
        uint256 lockedUsdtValue;  // USDT value at entry
        uint256 prev;             // linked list prev
        uint256 next;             // linked list next
        bool    active;
    }

    uint256 public nextPositionId = 1; // 0 = sentinel
    mapping(uint256 => Position) public positions;
    mapping(address => uint256) public userPositionId; // 1 position per address

    // Queue heads/tails
    uint256 public smallHead; // <500U queue head
    uint256 public smallTail;
    uint256 public regularHead; // ≥500U queue head
    uint256 public regularTail;
    uint256 public smallCount;
    uint256 public regularCount;

    event ExitQueued(address indexed user, uint256 positionId, uint256 usdtValue, bool isSmall);
    event ExitSettled(address indexed user, uint256 usdtPaid);
    event Accelerated(address indexed user, uint256 positionsMoved);

    modifier onlyATM() {
        require(msg.sender == atmToken, "NOT_ATM");
        _;
    }

    constructor(address _atm, address _usdt) {
        atmToken = _atm;
        usdt = _usdt;
    }

    /// @notice Called by ATMToken hook on transfer to EXIT_HOLE
    function onExitEntry(
        address user,
        uint256 atmAmount,
        uint256 usdtValue
    ) external onlyATM returns (bool) {
        // Check if user already has position (acceleration)
        if (userPositionId[user] != 0) {
            return _handleAcceleration(user, atmAmount, usdtValue);
        }

        // New entry
        require(usdtValue >= MIN_EXIT_U, "EXIT_TOO_SMALL");
        require(usdtValue <= MAX_EXIT_U, "EXIT_TOO_BIG");

        uint256 posId = nextPositionId++;
        bool isSmall = usdtValue < SPLIT_THRESHOLD;

        positions[posId] = Position({
            user: user,
            lockedUsdtValue: usdtValue,
            prev: 0,
            next: 0,
            active: true
        });
        userPositionId[user] = posId;

        // Append to appropriate queue
        if (isSmall) {
            _appendToQueue(posId, true);
            smallCount++;
        } else {
            _appendToQueue(posId, false);
            regularCount++;
        }

        emit ExitQueued(user, posId, usdtValue, isSmall);
        return true;
    }

    function _handleAcceleration(address user, uint256 atmAmount, uint256 usdtValue) private returns (bool) {
        require(usdtValue >= 1e18, "ACCEL_MIN_1U");

        uint256 posId = userPositionId[user];
        require(positions[posId].active, "NOT_ACTIVE");

        uint256 effectiveU = usdtValue > MAX_ACCEL_U ? MAX_ACCEL_U : usdtValue;
        uint256 steps = effectiveU / 1e18; // 1U = 1 position forward, max 10U = 10 positions
        uint256 usedU = steps * 1e18; // actual USDT consumed (integer U only)

        // Refund ALL unused ATM: both >10U excess AND sub-integer fraction
        uint256 unusedU = usdtValue - usedU; // e.g. 5.3U → used 5U → unused 0.3U; 15U → used 10U → unused 5U
        if (unusedU > 0 && atmAmount > 0) {
            uint256 refundATM = atmAmount * unusedU / usdtValue;
            if (refundATM > 0) {
                IATMToken(atmToken).internalTransferFrom(EXIT_HOLE, user, refundATM);
            }
        }

        if (steps == 0) return true; // nothing to move

        // Determine which queue this position is in
        bool isSmall = positions[posId].lockedUsdtValue < SPLIT_THRESHOLD;
        uint256 head = isSmall ? smallHead : regularHead;

        // Already at head? Revert — no point paying to accelerate
        require(posId != head, "ALREADY_HEAD");

        // Move forward
        uint256 moved = 0;
        uint256 current = posId;

        for (uint256 i = 0; i < steps; i++) {
            uint256 prevId = positions[current].prev;
            if (prevId == 0) break; // already at head
            // Swap current with prev
            _swapPositions(prevId, current, isSmall);
            moved++;
        }

        emit Accelerated(user, moved);
        return true;
    }

    function _appendToQueue(uint256 posId, bool isSmall) private {
        if (isSmall) {
            if (smallTail == 0) {
                smallHead = posId;
                smallTail = posId;
            } else {
                positions[smallTail].next = posId;
                positions[posId].prev = smallTail;
                smallTail = posId;
            }
        } else {
            if (regularTail == 0) {
                regularHead = posId;
                regularTail = posId;
            } else {
                positions[regularTail].next = posId;
                positions[posId].prev = regularTail;
                regularTail = posId;
            }
        }
    }

    function _swapPositions(uint256 a, uint256 b, bool isSmall) private {
        // a is before b. After swap, b should be before a.
        Position storage posA = positions[a];
        Position storage posB = positions[b];

        uint256 prevA = posA.prev;
        uint256 nextB = posB.next;

        // Link prevA → b
        if (prevA != 0) {
            positions[prevA].next = b;
        } else {
            // a was head
            if (isSmall) smallHead = b;
            else regularHead = b;
        }

        // Link b → a
        posB.prev = prevA;
        posB.next = a;

        // Link a → nextB
        posA.prev = b;
        posA.next = nextB;

        // Link nextB.prev → a
        if (nextB != 0) {
            positions[nextB].prev = a;
        } else {
            // b was tail
            if (isSmall) smallTail = a;
            else regularTail = a;
        }
    }

    /// @notice Settle exits with available USDT
    /// @param availableUSDT Total USDT sent by ATMToken for this batch
    /// @return used Amount of USDT actually consumed
    function settleExits(uint256 availableUSDT) external onlyATM returns (uint256 used) {
        uint256 smallBudget = availableUSDT / 2;
        uint256 regularBudget = availableUSDT - smallBudget;

        // Settle small queue
        uint256 smallUsed = _settleQueue(true, smallBudget);

        // Settle regular queue  
        uint256 regularUsed = _settleQueue(false, regularBudget);

        // Cross-allocate unused budget
        if (smallUsed < smallBudget && regularCount > 0) {
            uint256 extra = smallBudget - smallUsed;
            regularUsed += _settleQueue(false, extra);
        }
        if (regularUsed < regularBudget && smallCount > 0) {
            uint256 extra = regularBudget - regularUsed;
            smallUsed += _settleQueue(true, extra);
        }

        used = smallUsed + regularUsed;

        // Return unused USDT
        uint256 unused = availableUSDT - used;
        if (unused > 0) {
            IERC20(usdt).safeTransfer(atmToken, unused);
        }
    }

    function _settleQueue(bool isSmall, uint256 budget) private returns (uint256 used) {
        uint256 head = isSmall ? smallHead : regularHead;
        uint256 settled = 0;

        while (head != 0 && budget > 0 && settled < BATCH_SIZE) {
            Position storage pos = positions[head];
            uint256 owed = pos.lockedUsdtValue * PAYOUT_MULT / 100;

            if (owed > budget) break; // not enough for this position

            // Pay out
            IERC20(usdt).safeTransfer(pos.user, owed);
            used += owed;
            budget -= owed;

            // Update exit quota on ATMToken for P5 dividend eligibility
            // Weight = lockedUsdtValue (the original value user locked, not the 1.5x payout)
            IATMToken(atmToken).updateExitQuota(pos.user, pos.lockedUsdtValue);

            // Remove from queue
            pos.active = false;
            userPositionId[pos.user] = 0;
            uint256 nextId = pos.next;

            if (isSmall) {
                smallHead = nextId;
                if (nextId != 0) positions[nextId].prev = 0;
                else smallTail = 0;
                smallCount--;
            } else {
                regularHead = nextId;
                if (nextId != 0) positions[nextId].prev = 0;
                else regularTail = 0;
                regularCount--;
            }

            emit ExitSettled(pos.user, owed);
            head = nextId;
            settled++;
        }
    }

    // ═══════════ View Helpers ═══════════
    function hasPosition(address user) external view returns (bool) {
        return userPositionId[user] != 0 && positions[userPositionId[user]].active;
    }

    function getQueueHead(bool isSmall) external view returns (address user, uint256 usdtOwed) {
        uint256 head = isSmall ? smallHead : regularHead;
        if (head == 0) return (address(0), 0);
        Position storage pos = positions[head];
        return (pos.user, pos.lockedUsdtValue * PAYOUT_MULT / 100);
    }

    function queueLength(bool isSmall) external view returns (uint256) {
        return isSmall ? smallCount : regularCount;
    }

    /// @notice Emergency: return all USDT to ATMToken (for failed settle recovery)
    function returnUnusedUSDT() external onlyATM {
        uint256 bal = IERC20(usdt).balanceOf(address(this));
        if (bal > 0) {
            IERC20(usdt).safeTransfer(atmToken, bal);
        }
    }
}
