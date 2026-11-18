// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Eth, Node, NativeVaultFixed} from "./38489-h-01-user-can-prevent-balance-updates-by-withdrawing-pashov.sol";

contract Finding38489Test is Test {
    function test_exploit_withdraw_bricks_the_slash_snapshot() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.snapshotReverted(), "snapshot reverted");
        assertEq(e.eth().balanceOf(address(e)), 8 ether, "paid 8");
        assertEq(e.vault().creditedNodeETH(), 8 ether, "credited unchanged");
        assertEq(e.vault().pendingSlash(), 4 ether, "slash unapplied");
        assertEq(e.eth().balanceOf(address(e.node())), 2 ether, "2 left");
    }

    function test_control_decrement_lets_the_snapshot_finish() public {
        Eth eth = new Eth();
        Node node = new Node(eth);
        NativeVaultFixed vault = new NativeVaultFixed(eth, node);
        eth.mint(address(node), 10 ether);
        vault.credit(8 ether);
        vault.queueSlash(4 ether);
        vault.finishWithdraw(address(this), 8 ether);
        assertEq(vault.creditedNodeETH(), 0, "credited reduced");
        uint256 unattributed = vault.startSnapshot();
        assertEq(unattributed, 2 ether, "snapshot returns 2");
        assertEq(eth.balanceOf(address(node)), 2 ether, "node still 2");
    }
}
