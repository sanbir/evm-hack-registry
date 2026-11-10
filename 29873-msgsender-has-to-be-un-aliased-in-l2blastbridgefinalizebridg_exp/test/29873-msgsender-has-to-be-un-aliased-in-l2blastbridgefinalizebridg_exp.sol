// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Exploit, L2BlastBridgeFixed} from "./29873-msgsender-has-to-be-un-aliased-in-l2blastbridgefinalizebridg.sol";

contract Finding29873Test is Test {
    function test_exploit_aliasedFinalizeRevertsAndLocksFiveSteth() public {
        Exploit e = new Exploit();
        e.run();

        console.log("locked stETH", e.lockedSteth());
        console.log("credited ETH", e.creditedEth());
        console.log("released", e.bridge().released());

        assertTrue(e.finalizeReverted(), "finalize did not revert");
        assertEq(e.lockedSteth(), 5 ether, "locked");
        assertEq(e.creditedEth(), 0, "credited");
        assertEq(e.steth().balanceOf(address(e.escrow())), 5 ether, "escrow");
        assertEq(e.steth().balanceOf(address(e.depositor())), 0, "depositor stETH");
        assertEq(address(e.depositor()).balance, 0, "depositor ETH");
        assertEq(e.bridge().released(), 0, "released");
        assertTrue(address(e.relay()) != e.bridge().OTHER_BRIDGE(), "alias");
    }

    function test_control_unaliasCreditsFiveEth() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 5 ether);
        e.control{value: 5 ether}();

        assertEq(address(e.depositor()).balance, 5 ether, "control credit");
        assertEq(L2BlastBridgeFixed(address(e.fixedBridge())).released(), 5 ether, "control release");
        assertEq(e.steth().balanceOf(address(e.escrow())), 5 ether, "stETH still escrowed as yield");
    }
}
