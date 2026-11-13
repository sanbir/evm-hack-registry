// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20Mini, TokenRewards, Pod} from "./52748-h-3-pod-dos-if-the-leave-as-paired-lp-token-option-is-enable.sol";

contract Finding52748Test is Test {
    function test_exploit_debond_reverts_and_peas_stay_in_the_pod() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.debondReverted(), "debond reverted");
        assertEq(e.locked(), 100 ether, "100 PEAS locked");
        assertEq(e.peas().balanceOf(address(e.pod())), 100 ether, "pod still holds PEAS");
        assertEq(e.peas().balanceOf(address(e)), 0, "user got nothing");
        assertEq(e.pod().bonded(address(e)), 100 ether, "bond record remains");
    }

    function test_control_burn_path_lets_debond_return_peas() public {
        ERC20Mini peas = new ERC20Mini("PEAS");
        ERC20Mini paired = new ERC20Mini("DAI");
        ERC20Mini reward = new ERC20Mini("RWD");
        ERC20Mini pool = new ERC20Mini("LP");
        TokenRewards rewards = new TokenRewards(address(paired), address(reward), address(this), true, true);
        Pod pod = new Pod(peas, paired, pool, rewards);

        peas.mint(address(this), 100 ether);
        peas.approve(address(pod), 100 ether);
        pod.bond(100 ether);
        paired.mint(address(pool), 1 ether);
        paired.mint(address(pod), 10 ether);

        pod.debond(100 ether);

        assertEq(peas.balanceOf(address(this)), 100 ether, "user recovered PEAS");
        assertEq(peas.balanceOf(address(pod)), 0, "pod empty");
        assertEq(pod.bonded(address(this)), 0, "bond cleared");
    }
}
