// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, OrderHandler} from "./18634-h-8-malicious-revert-reasons-with-faked-lengths-can-disrupt.sol";

contract Finding18634Test is Test {
    address internal constant ACCOUNT = 0x1111111111111111111111111111111111111111;
    address internal constant INSURANCE = 0x3333333333333333333333333333333333333333;

    function test_faked_length_oogs_liquidation_and_leaves_collateral() public {
        Exploit e = new Exploit();
        e.run();

        OrderHandler handler = e.handler();
        assertEq(e.revertLen(), 100, "short revert payload");
        assertEq(e.statedLen(), 100_000_000_000, "faked length word");
        assertEq(e.batchOk(), false, "keeper execute reverted");
        assertEq(e.wasSeized(), false, "not seized");
        assertEq(e.stillLocked(), 1000 ether, "1000 stays locked");
        assertEq(e.vaultBalance(), 1000 ether, "vault holds 1000");
        assertEq(e.insuranceBalance(), 0, "insurance got nothing");
        assertEq(handler.locked(ACCOUNT), 1000 ether, "account escrow");
        assertEq(e.token().balanceOf(address(handler)), 1000 ether, "token escrow");
        assertEq(handler.filled(e.positionKey()), false, "order not filled");

        console2.log("revert bytes", e.revertLen());
        console2.log("stated length", e.statedLen());
        console2.log("locked", e.stillLocked());
        console2.log("vault", e.vaultBalance());
    }

    function test_control_rejects_faked_length_and_seizes() public {
        Exploit e = new Exploit();
        e.runControl();

        assertEq(e.controlOk(), true, "control execute ok");
        assertEq(e.controlSeized(), true, "seized");
        assertEq(e.controlVault(), 0, "handler emptied");
        assertEq(e.controlInsurance(), 1000 ether, "insurance received 1000");
        assertEq(e.token().balanceOf(INSURANCE), 1000 ether, "insurance token balance");

        console2.log("control insurance", e.controlInsurance());
        console2.log("control vault", e.controlVault());
    }
}
