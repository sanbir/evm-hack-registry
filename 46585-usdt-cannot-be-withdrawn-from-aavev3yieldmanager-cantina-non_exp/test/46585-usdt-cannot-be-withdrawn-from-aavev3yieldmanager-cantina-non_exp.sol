// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, NonReturningUSDT, AaveV3YieldManager} from
    "./46585-usdt-cannot-be-withdrawn-from-aavev3yieldmanager-cantina-non.sol";

contract Finding46585Test is Test {
    function test_exploit_usdt_withdraw_reverts_and_locks_1000() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.usdt().balanceOf(address(e.manager())), 1000e6, "manager still holds 1000 USDT");
        assertEq(e.usdt().balanceOf(address(e)), 0, "caller received 0");
    }

    function test_control_direct_usdt_transfer_pays_the_caller() public {
        NonReturningUSDT usdt = new NonReturningUSDT();
        AaveV3YieldManager manager = new AaveV3YieldManager(address(usdt), address(0xA11CE), address(0xB0B));
        usdt.mint(address(manager), 1000e6);
        manager.withdrawSafe(address(usdt), 1000e6);
        assertEq(usdt.balanceOf(address(this)), 1000e6, "safe path delivers 1000 USDT");
        assertEq(usdt.balanceOf(address(manager)), 0, "manager is empty");
    }
}
