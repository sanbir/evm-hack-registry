// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Share, ZetaBank} from
    "./58632-h-2-dirty-evm-state-changes-are-not-committed-before-precomp.sol";

contract Finding58632Test is Test {
    function test_exploit_double_spends_100_zeta() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.deadZeta(), 100 ether, "dead");
        assertEq(e.staked(), 100 ether, "staked");
        assertEq(e.deadZeta() + e.staked(), 200 ether, "200 from 100");
        assertEq(e.share().balanceOf(address(e)), 100 ether, "shares");
    }

    function test_control_commit_before_stake_delegates_nothing() public {
        Share share = new Share();
        ZetaBank bank = new ZetaBank(share);
        bank.fund(address(this), 100 ether);
        bank.transfer(bank.DEAD(), 100 ether);
        bank.commit(address(this));
        assertEq(bank.cosmosBalance(address(this)), 0, "cosmos sees the transfer");
        vm.expectRevert();
        bank.stake(100 ether);
        assertEq(bank.delegated(address(this)), 0, "no delegation");
        assertEq(bank.cosmosBalance(bank.DEAD()), 100 ether, "dead kept the only 100");
        assertEq(share.balanceOf(address(this)), 0, "no shares");
    }
}
