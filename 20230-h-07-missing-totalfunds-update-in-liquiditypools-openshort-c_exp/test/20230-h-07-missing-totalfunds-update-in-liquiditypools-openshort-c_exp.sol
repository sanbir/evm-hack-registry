// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20230-h-07-missing-totalfunds-update-in-liquiditypools-openshort-c.sol";

/// @dev forge-std driver for the reduced Polynomial H-07 PoC.
contract MissingTotalFundsUpdateTest is Test {
    Exploit exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    function test_missingTotalFundsUpdate() public {
        exploit.run();

        LiquidityPool pool = exploit.pool();
        MockERC20 susd = exploit.susd();
        uint256 netFee = exploit.netFee();
        uint256 lpDeposit = exploit.LP_DEPOSIT();
        uint256 lpRedeemed = exploit.lpRedeemed();

        // The LP earned a net fee but was paid back only its principal.
        assertEq(lpRedeemed, lpDeposit, "LP should receive only principal");
        assertLt(lpRedeemed, lpDeposit + netFee, "LP should be shortchanged by the net fee");

        // The uncredited net fee is stuck in the pool with no LP tokens left.
        assertEq(susd.balanceOf(address(pool)), netFee, "net fee should be stuck in pool");
        assertEq(pool.totalSupply(), 0, "no LP tokens should remain");
        assertGt(netFee, 0, "net fee must be positive");
    }
}
