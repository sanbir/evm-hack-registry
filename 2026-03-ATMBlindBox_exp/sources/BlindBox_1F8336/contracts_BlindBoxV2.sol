// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IATMInterfaces.sol";

/**
 * @title BlindBox — 盲盒竞猜模块
 * @notice dEaD黑洞, 1.95x币本位赔付, N+2区块哈希
 */
contract BlindBox {
    address public immutable atmToken;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Testnet params
    uint256 public constant MIN_BET_ATM = 1e18;   // minimum 1 ATM (not USD-based)
    uint256 public constant MAX_BET_U = 3000e18;  // 3000 USDT
    uint256 public constant PAYOUT_MULT = 195;     // 1.95x (195/100)

    struct Bet {
        address user;
        uint256 amount;     // ATM amount
        uint256 blockNum;   // entry block
        uint256 oddDigit;   // user's parity (0=even, 1=odd)
        bool settled;
    }

    uint256 public nextBetId;
    mapping(uint256 => Bet) public bets;
    mapping(uint256 => bytes32) public cachedBlockHash;
    uint256 public lastUnsettledId;

    // BNB gas reserve
    uint256 public gasReserve;
    bool public charging = true;
    uint256 public constant RESERVE_LOW  = 0.05 ether;
    uint256 public constant RESERVE_HIGH = 0.2 ether;
    uint256 public constant DEPOSIT_AMOUNT = 0.0001 ether;

    event BetPlaced(uint256 indexed betId, address indexed user, uint256 amount, uint256 blockNum);
    event BetSettled(uint256 indexed betId, address indexed user, bool won, uint256 payout);

    modifier onlyATM() {
        require(msg.sender == atmToken, "NOT_ATM");
        _;
    }

    constructor(address _atm) {
        atmToken = _atm;
    }

    /// @notice Called by ATMToken hook when user sends ATM to dEaD
    function onBlindBoxEntry(
        address user,
        uint256 amount,
        uint256 reserveATM,
        uint256 reserveUSDT
    ) external onlyATM returns (bool) {
        // Check minimum: 1 ATM (token-based, not gold-standard)
        require(amount >= MIN_BET_ATM, "BET_TOO_SMALL");
        // Check maximum: 3000U (gold-standard)
        uint256 usdtValue = amount * reserveUSDT / reserveATM;
        require(usdtValue <= MAX_BET_U, "BET_TOO_BIG");

        // Check dEaD has enough for payout
        uint256 deadBal = IATMToken(atmToken).balanceOf(DEAD);
        require(deadBal >= amount * PAYOUT_MULT / 100, "DEAD_LOW");

        // Miner exclusion
        require(tx.origin != block.coinbase, "MINER_EXCLUDED");

        // Get user's odd/even from last digit of amount
        uint256 lastDigit = (amount / 1e17) % 10; // units digit in ATM (10^17 = 0.1 ATM)
        uint256 parity = _isOdd(lastDigit) ? 1 : 0;

        // Record bet
        uint256 betId = nextBetId++;
        bets[betId] = Bet({
            user: user,
            amount: amount,
            blockNum: block.number,
            oddDigit: parity,
            settled: false
        });

        emit BetPlaced(betId, user, amount, block.number);

        // Try to settle previous bet
        _trySettle(lastUnsettledId);

        return true;
    }

    /// @notice Public settle function
    function settle(uint256 betId) external {
        _trySettle(betId);
    }

    /// @notice Batch settle
    function batchSettle(uint256 fromId, uint256 toId) external {
        for (uint256 i = fromId; i <= toId && i < nextBetId; i++) {
            _trySettle(i);
        }
    }

    function _trySettle(uint256 betId) private {
        if (betId >= nextBetId) return;
        Bet storage bet = bets[betId];
        if (bet.settled) return;
        if (bet.amount == 0) return;

        uint256 targetBlock = bet.blockNum + 2;
        if (block.number <= targetBlock) return; // N+2 not yet mined

        // Get block hash
        bytes32 hash = cachedBlockHash[targetBlock];
        if (hash == bytes32(0)) {
            hash = blockhash(targetBlock);
            if (hash == bytes32(0)) {
                // BLOCKHASH expired — use fallback
                hash = keccak256(abi.encodePacked(block.prevrandao, betId, block.timestamp));
            }
            cachedBlockHash[targetBlock] = hash;
        }

        // Determine result
        uint256 resultDigit = uint256(hash) % 16; // 0-15
        uint256 resultParity = _isOdd(resultDigit) ? 1 : 0;
        bool won = (resultParity == bet.oddDigit);

        bet.settled = true;

        if (won) {
            // Payout: 1.95x 币本位 from dEaD to user
            uint256 payout = bet.amount * PAYOUT_MULT / 100;
            // Use ATMToken internalTransferFrom to move ATM from dEaD to user
            IATMToken(atmToken).internalTransferFrom(DEAD, bet.user, payout);
        }

        // Advance unsettled pointer
        while (lastUnsettledId < nextBetId && bets[lastUnsettledId].settled) {
            lastUnsettledId++;
        }

        emit BetSettled(betId, bet.user, won, won ? bet.amount * PAYOUT_MULT / 100 : 0);
    }

    function _isOdd(uint256 digit) private pure returns (bool) {
        // Odd: 1,3,5,7,9,B(11),D(13),F(15)
        // Even: 0,2,4,6,8,A(10),C(12),E(14)
        return digit % 2 == 1;
    }

    // BNB deposit management
    function depositGas() external payable {
        gasReserve += msg.value;
        _updateCharging();
    }

    function _updateCharging() private {
        if (gasReserve < RESERVE_LOW) {
            charging = true;
        } else if (gasReserve >= RESERVE_HIGH) {
            charging = false;
        }
        // Between LOW and HIGH: maintain current state (hysteresis)
    }

    receive() external payable {
        gasReserve += msg.value;
        _updateCharging();
    }

    // View helpers
    function balanceOf(address addr) private view returns (uint256) {
        (bool ok, bytes memory data) = atmToken.staticcall(
            abi.encodeWithSignature("balanceOf(address)", addr)
        );
        require(ok, "BALANCE_CALL_FAILED");
        return abi.decode(data, (uint256));
    }
}

// IATMToken defined in IATMInterfaces.sol
