// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {SettlementBranch, LiquidationBranch, Exploit} from
    "./37983-settlementbranch-fillorder-does-not-guarantee-the-collateral.sol";

contract InsufficientLiquidationMarginTest is Test {
    /// @notice CONTROL — a trader who deposits enough to cover BOTH the
    ///         opening fees AND the fixed liquidation fee is liquidated
    ///         cleanly: the fee recipient gets the full fee and the
    ///         market-making engine gets its full pnl.
    function test_sufficientMargin_liquidatesCleanly() public {
        SettlementBranch settlement = new SettlementBranch();
        address feeRecipient = address(0xFEE);
        address marketMaking = address(0x1234);
        LiquidationBranch liquidation = new LiquidationBranch(settlement, feeRecipient, marketMaking);

        uint256 accountId = 1;
        settlement.deposit(accountId, 12e18); // enough to cover fees + full liquidation fee + pnl
        settlement.fillOrder(accountId, 2e18, 1e18); // remaining margin: 9

        assertGe(settlement.marginBalance(accountId), settlement.LIQUIDATION_FEE_USD());

        (uint256 feePaid, uint256 marketMakingPaid) = liquidation.liquidate(accountId, 3e18);
        assertEq(feePaid, 5e18); // full fixed fee paid
        assertEq(marketMakingPaid, 3e18); // full pnl paid
    }

    /// @notice HARM — a trader who deposits only enough to cover the
    ///         OPENING fees (leaving far less than the fixed liquidation
    ///         fee) is still allowed to open the position. On liquidation,
    ///         the fee recipient is shorted AND the market-making engine
    ///         receives nothing.
    function test_insufficientMargin_shortsFeeRecipientAndMarketMaking() public {
        Exploit exploit = new Exploit();
        exploit.run();
    }
}
