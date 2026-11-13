// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, ERC20, IndexUtils, CompounderFixed} from
    "./52749-h-4-autocompoundingpodlp-pairedlptokentopodlp-does-not-corr.sol";

contract Finding52749Test is Test {
    function test_exploit_unbalanced_add_sticks_ptkn() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.compounder().lpOut(), 0, "no lp");
        assertEq(e.stuckPod(), 12925820234006285946425, "pod stuck");
        assertEq(e.stuckPaired(), 5851640468012571892851, "paired stuck");
    }

    function test_control_pairing_leftover_first_mints_lp() public {
        ERC20 paired = new ERC20("PAIRED");
        ERC20 pod = new ERC20("pTKN");
        IndexUtils utils = new IndexUtils(pod, paired);
        CompounderFixed compounder = new CompounderFixed(paired, pod, utils);
        pod.mint(address(compounder), 10000 ether);
        paired.mint(address(compounder), 10000 ether);
        uint256 lp = compounder.compound(10000 ether);
        assertEq(lp, 10000 ether, "lp");
        assertEq(pod.balanceOf(address(compounder)), 0, "pod clear");
        assertEq(paired.balanceOf(address(compounder)), 0, "paired clear");
    }
}
