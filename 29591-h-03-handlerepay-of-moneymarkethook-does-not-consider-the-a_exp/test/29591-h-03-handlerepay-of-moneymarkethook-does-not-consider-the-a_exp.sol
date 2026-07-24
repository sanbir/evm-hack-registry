// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./29591-h-03-handlerepay-of-moneymarkethook-does-not-consider-the-a.sol";

/*//////////////////////////////////////////////////////////////
    INIT Capital — [H-03] MoneyMarketHook#_handleRepay can leave
    user tokens stuck. Finding #29591 (code4rena, said) — HIGH.
//////////////////////////////////////////////////////////////*/
contract HandleRepayStuckTokensTest is Test {
    /// @notice CONTROL: when the position still holds the full debt the
    ///         hook pulls, InitCore consumes everything and nothing is stuck.
    function test_control_fullRepayConsumesAll() public {
        MockToken token = new MockToken();
        MockLendingPool pool = new MockLendingPool(token);
        InitCoreVuln core = new InitCoreVuln(pool);
        MoneyMarketHookVuln hook = new MoneyMarketHookVuln(core, pool);

        uint256 posId = 1;
        uint256 debt = 1000e18;
        pool.setDebtShares(posId, debt);

        token.mint(address(this), debt);
        token.approve(address(hook), debt);

        MoneyMarketHookVuln.RepayParams memory p =
            MoneyMarketHookVuln.RepayParams({pool: address(pool), shares: debt});
        hook.handleRepay(posId, p);

        assertEq(token.balanceOf(address(hook)), 0, "no surplus when debt matches");
        assertEq(pool.getPosDebtShares(posId), 0, "debt fully repaid");
        assertEq(token.balanceOf(address(pool)), debt, "pool received full amount");
    }

    /// @notice HARM: liquidator zeros debt first; user's full-debt repay via
    ///         the hook still pulls the full amount which then stays stuck.
    function test_handleRepay_tokensStuckAfterLiquidation() public {
        Exploit exploit = new Exploit();
        exploit.run();

        assertEq(
            exploit.token().balanceOf(address(exploit.hook())),
            exploit.DEBT_SHARES(),
            "full repayAmt should be stuck in the hook"
        );
        assertEq(exploit.pool().getPosDebtShares(exploit.POS_ID()), 0, "debt remains zero");
        assertEq(exploit.token().balanceOf(address(exploit)), 0, "user lost their tokens");
    }
}
