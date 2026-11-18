// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Collat, TradingStorageFixed} from
    "./37795-h-06-wrong-validation-in-togglecollateralactivestate-pashov.sol";

contract Finding37795Test is Test {
    function test_exploit_toggle_reverts_and_1000_collateral_trade_opens() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.toggleReverted(), "toggle reverted");
        (, bool active) = e.trading().collaterals(1);
        assertTrue(active, "still active");
        assertEq(e.opened(), 1000 ether, "1000 opened");
        assertEq(e.token().balanceOf(address(e.trading())), 1000 ether, "vault holds 1000");
    }

    function test_control_precision_eq_zero_disables_collateral() public {
        Collat token = new Collat();
        TradingStorageFixed trading = new TradingStorageFixed(token);
        trading.addCollateral(1, 1e18);
        trading.toggleCollateralActiveState(1);
        (, bool active) = trading.collaterals(1);
        assertFalse(active, "disabled");

        token.mint(address(this), 1000 ether);
        token.approve(address(trading), 1000 ether);
        vm.expectRevert(bytes("inactive"));
        trading.openTrade(1, 1000 ether);
        assertEq(trading.openCollateral(), 0, "no trade");
        assertEq(token.balanceOf(address(trading)), 0, "vault empty");
    }
}
