// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IATMTokenCallback {
    function onP4Decay(uint256 amount) external;
}

/**
 * @title Lottery — 抽奖模块 (P3→P4 injection + countdown + random draw)
 * @notice 倒计时(3-6min testnet), N+2区块哈希, 分3批结算
 */
contract Lottery {
    using SafeERC20 for IERC20;

    address public immutable atmToken;
    address public immutable usdt;

    // ═══════════ Testnet Time Params ═══════════
    uint256 public constant INITIAL_COUNTDOWN = 180;   // 3min (prod: 60min)
    uint256 public constant MAX_COUNTDOWN     = 360;   // 6min (prod: 120min)
    uint256 public constant ADDR_INFLUENCE_MAX = 60;   // ±1min (prod: ±10min)
    uint256 public constant BUY_DECREMENT     = 1;     // -1 sec per buy (prod: -60)
    uint256 public constant SELL_INCREMENT    = 1;     // +1 sec per sell (prod: +60)
    uint256 public constant P3_DENOMINATOR    = 360;
    uint256 public constant P3_ACCEL_TIME     = 120;   // 2min (prod: 24h)
    uint256 public constant P3_FREEZE_TIME    = 300;   // 5min (prod: 48h)
    uint256 public constant P4_DECAY_INTERVAL = 300;   // 5min (prod: 24h)
    uint256 public constant ZERO_ROUND_FREEZE = 10;    // 10 rounds for freeze
    uint256 public constant BIG_WINNER_COOLDOWN = 3;   // 3 rounds

    // ═══════════ Round State ═══════════
    uint256 public currentRound;
    uint256 public roundStartTime;
    uint256 public countdown; // seconds remaining
    uint256 public lastCountdownUpdate;

    // Ticket tracking
    struct TicketInfo {
        uint256 tickets;
        uint256 buyCount; // for decay: 1st full, 2nd ×0.7, 3rd ×0.4, 4th+ ×0.2
    }
    mapping(uint256 => mapping(address => TicketInfo)) public roundTickets; // round → user → info
    mapping(uint256 => mapping(address => int256)) public roundInfluence; // round → user → seconds influenced
    mapping(uint256 => address[]) public roundParticipants; // round → participant list
    mapping(uint256 => uint256) public roundTotalTickets;

    // Big winner cooldown
    mapping(address => uint256) public bigWinnerLastRound;

    // P3/P4 State
    uint256 public poolP3Balance; // mirror of ATMToken's poolP3
    uint256 public poolP4Balance;
    uint256 public lastP3IncomeTime;
    uint256 public consecutiveZeroRounds;
    bool public isFrozen;
    bool public isDecaying;
    uint256 public decayStartTime;

    // Settlement state
    uint256 public settleBlockNum; // block when round ended
    bool public pendingSettle;
    uint256 public settlePhase; // 0=not settling, 1=big, 2=small, 3=sunshine

    // ═══════════ Events ═══════════
    event RoundStarted(uint256 indexed round, uint256 countdown);
    event TicketAdded(uint256 indexed round, address indexed user, uint256 tickets);
    event CountdownUpdated(uint256 indexed round, uint256 newCountdown);
    event RoundEnded(uint256 indexed round, uint256 totalTickets, uint256 prizePool);
    event PrizeAwarded(uint256 indexed round, string tier, address indexed winner, uint256 amount);
    event P4Decayed(uint256 decayAmount, uint256 remaining);
    event FrozenStateChanged(bool frozen);

    modifier onlyATM() {
        require(msg.sender == atmToken, "NOT_ATM");
        _;
    }

    constructor(address _atm, address _usdt) {
        atmToken = _atm;
        usdt = _usdt;
        currentRound = 1;
        roundStartTime = block.timestamp;
        countdown = INITIAL_COUNTDOWN;
        lastCountdownUpdate = block.timestamp;
        lastP3IncomeTime = block.timestamp;
    }

    // ═══════════ Called by ATMToken on buy ═══════════
    function onBuy(address user, uint256 usdtValue) external onlyATM {
        if (usdtValue < 10e18) return; // <10U ignored

        // Calculate tickets: 1 per 10U
        uint256 baseTickets = usdtValue / 10e18;
        
        TicketInfo storage info = roundTickets[currentRound][user];
        info.buyCount++;
        
        // Decay multiplier: 1st=100%, 2nd=70%, 3rd=40%, 4th+=20%
        uint256 mult;
        if (info.buyCount == 1) mult = 100;
        else if (info.buyCount == 2) mult = 70;
        else if (info.buyCount == 3) mult = 40;
        else mult = 20;
        
        uint256 actualTickets = baseTickets * mult / 100;
        if (actualTickets == 0) actualTickets = 1; // minimum 1 ticket

        if (info.tickets == 0) {
            roundParticipants[currentRound].push(user);
        }
        info.tickets += actualTickets;
        roundTotalTickets[currentRound] += actualTickets;

        // Countdown: -1 per buy (capped by address influence)
        _adjustCountdown(user, -int256(BUY_DECREMENT));

        emit TicketAdded(currentRound, user, actualTickets);

        // Check if countdown hit 0
        _checkRoundEnd();
    }

    function onSell(address user, uint256 usdtValue) external onlyATM {
        if (usdtValue < 10e18) return;
        _adjustCountdown(user, int256(SELL_INCREMENT));
        _checkRoundEnd();
    }

    function _adjustCountdown(address user, int256 delta) private {
        // Calculate elapsed time
        uint256 elapsed = block.timestamp - lastCountdownUpdate;
        if (elapsed >= countdown) {
            countdown = 0;
            return;
        }
        countdown -= elapsed;
        lastCountdownUpdate = block.timestamp;

        // Check per-address influence cap
        int256 influence = roundInfluence[currentRound][user];
        int256 cap = int256(ADDR_INFLUENCE_MAX);
        
        if (delta < 0) {
            // Buy: reduce countdown — prevent influence from going below -cap
            if (influence + delta < -cap) {
                delta = -cap - influence;
            }
            if (delta >= 0) return; // already at max negative influence
        } else {
            // Sell: increase countdown — prevent influence from exceeding +cap
            if (influence + delta > cap) delta = cap - influence;
            if (delta <= 0) return;
        }
        
        roundInfluence[currentRound][user] += delta;

        if (delta < 0) {
            uint256 dec = uint256(-delta);
            countdown = countdown > dec ? countdown - dec : 0;
        } else {
            countdown += uint256(delta);
            if (countdown > MAX_COUNTDOWN) countdown = MAX_COUNTDOWN;
        }

        emit CountdownUpdated(currentRound, countdown);
    }

    function _checkRoundEnd() private {
        uint256 elapsed = block.timestamp - lastCountdownUpdate;
        if (elapsed >= countdown || countdown == 0) {
            // Round ended!
            _endRound();
        }
    }

    function _endRound() private {
        if (pendingSettle) return; // already ending

        uint256 totalTickets = roundTotalTickets[currentRound];
        
        if (totalTickets == 0) {
            consecutiveZeroRounds++;
            if (consecutiveZeroRounds >= ZERO_ROUND_FREEZE && !isFrozen) {
                isFrozen = true;
                isDecaying = true;
                decayStartTime = block.timestamp;
                emit FrozenStateChanged(true);
            }
            // Start new round
            _startNewRound();
            return;
        }

        consecutiveZeroRounds = 0;
        if (isFrozen) {
            isFrozen = false;
            isDecaying = false;
            emit FrozenStateChanged(false);
        }

        pendingSettle = true;
        settleBlockNum = block.number;
        settlePhase = 1;

        emit RoundEnded(currentRound, totalTickets, poolP4Balance);
    }

    /// @notice Keeper E settles prizes in 3 phases
    function settlePrize(uint256 round) external {
        require(pendingSettle, "NO_PENDING");
        require(block.number >= settleBlockNum + 2, "WAIT_N2");

        bytes32 seed = blockhash(settleBlockNum + 2);
        if (seed == bytes32(0)) {
            seed = keccak256(abi.encodePacked(block.prevrandao, round, block.timestamp));
        }

        uint256 totalTickets = roundTotalTickets[round];
        if (totalTickets == 0 || poolP4Balance == 0) {
            pendingSettle = false;
            _startNewRound();
            return;
        }

        // Determine distribution tier
        // Normal: 20% big, 20% small(5), 10% sunshine(20), 50% rollover
        uint256 bigPrize = poolP4Balance * 20 / 100;
        uint256 smallTotal = poolP4Balance * 20 / 100;
        uint256 sunshineTotal = poolP4Balance * 10 / 100;
        uint256 rollover = poolP4Balance - bigPrize - smallTotal - sunshineTotal;

        address[] memory participants = roundParticipants[round];

        // Big prize (1 winner)
        if (participants.length > 0 && bigPrize > 0) {
            address winner = _drawWinner(seed, 0, participants, roundTickets[round], totalTickets, round);
            if (winner != address(0)) {
                IERC20(usdt).safeTransfer(winner, bigPrize);
                bigWinnerLastRound[winner] = round;
                emit PrizeAwarded(round, "BIG", winner, bigPrize);
            } else {
                rollover += bigPrize;
            }
        } else {
            rollover += bigPrize;
        }

        // Small prizes (5 winners)
        uint256 perSmall = smallTotal / 5;
        for (uint256 i = 0; i < 5 && participants.length > 0; i++) {
            address winner = _drawWinner(seed, 1 + i, participants, roundTickets[round], totalTickets, round);
            if (winner != address(0) && perSmall > 0) {
                IERC20(usdt).safeTransfer(winner, perSmall);
                emit PrizeAwarded(round, "SMALL", winner, perSmall);
            } else {
                rollover += perSmall;
            }
        }

        // Sunshine prizes (20 winners)
        uint256 perSunshine = sunshineTotal / 20;
        for (uint256 i = 0; i < 20 && participants.length > 0; i++) {
            address winner = _drawWinner(seed, 6 + i, participants, roundTickets[round], totalTickets, round);
            if (winner != address(0) && perSunshine > 0) {
                IERC20(usdt).safeTransfer(winner, perSunshine);
                emit PrizeAwarded(round, "SUNSHINE", winner, perSunshine);
            } else {
                rollover += perSunshine;
            }
        }

        poolP4Balance = rollover;
        pendingSettle = false;
        _startNewRound();
    }

    function _drawWinner(
        bytes32 seed,
        uint256 index,
        address[] memory participants,
        mapping(address => TicketInfo) storage ticketMap,
        uint256 totalTickets,
        uint256 round
    ) private view returns (address) {
        for (uint256 retry = 0; retry < 100; retry++) {
            bytes32 hash = keccak256(abi.encodePacked(seed, index, retry));
            uint256 ticket = uint256(hash) % totalTickets;
            
            // Find winner by ticket position
            uint256 cumulative = 0;
            for (uint256 i = 0; i < participants.length; i++) {
                cumulative += ticketMap[participants[i]].tickets;
                if (ticket < cumulative) {
                    address candidate = participants[i];
                    // Big winner cooldown check
                    if (index == 0 && bigWinnerLastRound[candidate] + BIG_WINNER_COOLDOWN >= round) {
                        break; // retry
                    }
                    return candidate;
                }
            }
        }
        return address(0); // failed after 100 retries
    }

    function _startNewRound() private {
        currentRound++;
        roundStartTime = block.timestamp;
        countdown = INITIAL_COUNTDOWN;
        lastCountdownUpdate = block.timestamp;
        settlePhase = 0;
        emit RoundStarted(currentRound, countdown);
    }

    /// @notice Inject P3 funds into P4 (called by Keeper or ATMToken)
    function injectP4(uint256 amount) external onlyATM {
        poolP4Balance += amount;
        lastP3IncomeTime = block.timestamp;
    }

    /// @notice Force end round after long freeze (public function, anyone can call after 48h)
    function forceEndRound() external {
        require(block.timestamp > roundStartTime + P3_FREEZE_TIME, "TOO_EARLY");
        _endRound();
    }

    /// @notice Trigger P4 decay when frozen
    function triggerDecay() external {
        require(isDecaying, "NOT_DECAYING");
        require(poolP4Balance > 0, "EMPTY");

        // 10% per call
        uint256 decay = poolP4Balance / 10;
        poolP4Balance -= decay;

        // 衰减USDT回流ATMToken，通过onP4Decay回调让ATMToken记账到poolP6（出局资金池）
        // 修复HIGH-1：原先safeTransfer后ATMToken无任何池子记账，导致"幽灵余额"
        IERC20(usdt).safeTransfer(atmToken, decay);
        IATMTokenCallback(atmToken).onP4Decay(decay);
        emit P4Decayed(decay, poolP4Balance);

        // If decaying for too long, return all to P0
        if (block.timestamp > decayStartTime + P4_DECAY_INTERVAL && poolP4Balance > 0) {
            uint256 remaining = poolP4Balance;
            poolP4Balance = 0;
            IERC20(usdt).safeTransfer(atmToken, remaining);
            // 剩余全额回流也需要记账
            IATMTokenCallback(atmToken).onP4Decay(remaining);
        }
    }

    // ═══════════ View Helpers ═══════════
    function getRoundInfo() external view returns (
        uint256 round, uint256 timeLeft, uint256 totalTickets, uint256 prizePool
    ) {
        uint256 elapsed = block.timestamp - lastCountdownUpdate;
        uint256 remaining = elapsed >= countdown ? 0 : countdown - elapsed;
        return (currentRound, remaining, roundTotalTickets[currentRound], poolP4Balance);
    }
}
