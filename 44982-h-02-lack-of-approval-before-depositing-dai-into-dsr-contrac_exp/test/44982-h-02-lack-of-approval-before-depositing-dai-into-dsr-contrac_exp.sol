// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Dai, SDai, DSRStrategyFixed} from "./44982-h-02-lack-of-approval-before-depositing-dai-into-dsr-contrac.sol";

contract Finding44982Test is Test {
    function test_exploit_deposit_reverts_and_dai_sticks() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.depositReverted(), "reverted");
        assertEq(e.dai().balanceOf(address(e.strategy())), 1000 ether, "1000 DAI stuck");
        assertEq(e.sdai().balanceOf(address(e.strategy())), 0, "no sDAI");
    }

    function test_control_approve_mints_sdai() public {
        Dai dai = new Dai();
        SDai sdai = new SDai(dai);
        DSRStrategyFixed strategy = new DSRStrategyFixed(dai, sdai);
        dai.mint(address(this), 1000 ether);
        dai.approve(address(strategy), 1000 ether);
        strategy.fund(1000 ether);
        uint256 got = strategy.deposit(1000 ether);
        assertEq(got, 100, "quoted return");
        assertEq(dai.balanceOf(address(strategy)), 0, "DAI left the strategy");
        assertEq(sdai.balanceOf(address(strategy)), 1000 ether, "1000 sDAI");
    }
}
