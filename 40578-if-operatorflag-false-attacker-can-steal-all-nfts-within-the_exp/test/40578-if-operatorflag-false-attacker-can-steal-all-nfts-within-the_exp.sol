// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    CoreGuarded
} from "./40578-if-operatorflag-false-attacker-can-steal-all-nfts-within-the.sol";

contract Finding40578Test is Test {
    function test_exploit_swaps_the_victim_nft_out() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.redeemed(), 1000 ether, "1000 USDC redeemed");
        assertEq(e.usdc().balanceOf(address(e)), 1000 ether, "attacker balance");
        assertEq(e.victimNow(), 2, "victim position now points at the attacker NFT");
        assertEq(e.nft().ownerOf(1), address(e), "attacker holds NFT 1");
        assertEq(e.usdc().balanceOf(address(e.nft())), 0, "custody empty");
    }

    function test_control_operator_flag_blocks_rebalance() public {
        CoreGuarded core = new CoreGuarded();
        vm.expectRevert(bytes("operator"));
        core.rebalance();
    }
}
