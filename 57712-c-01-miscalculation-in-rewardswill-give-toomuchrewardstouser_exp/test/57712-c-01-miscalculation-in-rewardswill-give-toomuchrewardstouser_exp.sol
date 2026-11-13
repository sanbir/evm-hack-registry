// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    RewardsVaultFixed,
    VictimStaker
} from "./57712-c-01-miscalculation-in-rewardswill-give-toomuchrewardstouser.sol";

contract Finding57712Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_cycle3_pays_the_first_withdrawer_double() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.accounted(), 40 ether, "40 booked on 30 deposited");
        assertEq(e.attackerPaid(), 20 ether, "first withdrawer");
        assertEq(e.victimPaid(), 10 ether, "second left short");
        assertEq(e.stolen(), 5 ether, "5 ether stolen vs fair 15");
        assertEq(e.yieldToken().balanceOf(SINK), 5 ether, "sink");
        assertEq(e.yieldToken().balanceOf(address(e)), 15 ether, "attacker keeps fair share");
    }

    function test_control_cumulative_last_reward_splits_30_evenly() public {
        MiniToken yieldToken = new MiniToken();
        RewardsVaultFixed vault = new RewardsVaultFixed(yieldToken);
        VictimStaker victim = new VictimStaker();
        vault.join();
        victim.joinFixed(vault);
        yieldToken.mint(address(this), 30 ether);
        yieldToken.approve(address(vault), type(uint256).max);
        vault.donate(10 ether);
        vault.syncRewards();
        vault.donate(10 ether);
        vault.syncRewards();
        vault.donate(10 ether);
        vault.syncRewards();
        assertEq(vault.accountedRewards(), 30 ether, "accounted");
        assertEq(vault.lastRewardAmount(), 30 ether, "cumulative");
        vault.withdraw();
        victim.withdrawFixed(vault);
        assertEq(vault.paid(address(this)), 15 ether, "attacker fair");
        assertEq(vault.paid(address(victim)), 15 ether, "victim fair");
    }
}
