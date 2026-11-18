// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Eth, Node, SlashStore, NativeVaultFixed} from "./38490-h-02-broken-balance-update-if-a-slash-event-happens-pashov-a.sol";

contract Finding38490Test is Test {
    function test_exploit_slash_freezes_the_remaining_eth() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.withdrawReverted(), "withdraw reverted");
        assertEq(e.eth().balanceOf(address(e.node())), 7 ether, "7 frozen");
        assertEq(e.eth().balanceOf(address(e.slashStore())), 3 ether, "store 3");
        assertEq(e.vault().creditedNodeETH(), 8 ether, "credited stuck at 8");
    }

    function test_control_slash_decrements_credit_and_snapshot_works() public {
        Eth eth = new Eth();
        Node node = new Node(eth);
        SlashStore store = new SlashStore(eth);
        NativeVaultFixed vault = new NativeVaultFixed(eth, node, store);
        eth.mint(address(node), 10 ether);
        vault.credit(8 ether);
        vault.transferToSlashStore(3 ether);
        assertEq(vault.creditedNodeETH(), 5 ether, "credited 5");
        uint256 unattributed = vault.startSnapshot();
        assertEq(unattributed, 2 ether, "7 - 5");
        assertEq(eth.balanceOf(address(node)), 7 ether, "node 7");
    }
}
