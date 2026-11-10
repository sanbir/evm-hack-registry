// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    OrderHandler
} from "./18632-h-6-keepers-can-be-forced-to-waste-gas-with-long-revert-mess.sol";

contract Finding18632Test is Test {
    address internal constant HONEST = 0x2222222222222222222222222222222222222222;

    function test_long_revert_reverts_batch_and_locks_honest_collateral() public {
        Exploit e = new Exploit();
        e.run();

        OrderHandler handler = e.handler();
        console2.log("revert bytes", e.revertLen());
        console2.log("probe gas", e.probeGas());
        console2.log("batch ok", e.batchOk());
        console2.log("honest locked", e.honestLocked());
        console2.log("keeper budget", handler.keeperBudget());
        assertEq(e.revertLen() > 10_000, true, "revert blob");
        assertEq(e.batchOk(), false, "batch reverted");
        assertEq(e.honestFilled(), false, "honest not filled");
        assertEq(e.honestLocked(), 1000 ether, "1000 USDC stays locked");
        assertEq(e.vaultBalance(), 1000 ether, "vault holds 1000");
        assertEq(e.honestBalance(), 0, "honest received nothing");
        assertEq(handler.lockedOf(HONEST), 1000 ether, "handler escrow");
        assertEq(e.token().balanceOf(address(handler)), 1000 ether, "token escrow");
        assertEq(handler.isFilled(e.honestKey()), false, "order flag");
        assertGt(e.probeGas(), handler.CALLBACK_GAS_LIMIT() / 2, "callback spent the stipend");
        console2.log("vault balance", e.vaultBalance());
    }

    function test_control_isolates_revert_and_fills_honest_order() public {
        Exploit e = new Exploit();
        e.runControl();

        assertEq(e.controlOk(), true, "control batch ok");
        assertEq(e.controlFilled(), true, "honest filled");
        assertEq(e.controlLocked(), 0, "escrow released");
        assertEq(e.controlHonestBalance(), 1000 ether, "honest paid 1000");
        assertEq(e.token().balanceOf(HONEST), 1000 ether, "honest token balance");

        console2.log("control paid", e.controlHonestBalance());
        console2.log("control locked", e.controlLocked());
    }
}
