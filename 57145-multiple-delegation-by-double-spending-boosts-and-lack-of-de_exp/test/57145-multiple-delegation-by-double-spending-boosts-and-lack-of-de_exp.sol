// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, VeToken, Reward, BoostControllerFixed} from
    "./57145-multiple-delegation-by-double-spending-boosts-and-lack-of-de.sol";

contract Finding57145Test is Test {
    function test_exploit_same_boost_is_delegated_twice_and_paid() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.firstDelegation(), 100 ether, "first 100");
        assertEq(e.secondDelegation(), 100 ether, "second 100");
        assertEq(e.veLeft(), 100 ether, "ve balance untouched");
        assertEq(e.paid(), 200 ether, "paid both delegations");
        assertEq(e.reward().balanceOf(address(e)), 200 ether, "attacker holds 200");
    }

    function test_control_second_delegation_reverts_and_pays_100() public {
        VeToken ve = new VeToken();
        Reward reward = new Reward();
        BoostControllerFixed boost = new BoostControllerFixed(ve, reward);
        ve.mint(address(this), 100 ether);
        reward.mint(address(boost), 200 ether);
        boost.setRemaining(address(this), 100 ether);

        boost.delegateBoost(address(0xB2), 100 ether, 7 days);
        bool reverted;
        try boost.delegateBoost(address(0xB3), 100 ether, 7 days) {
            reverted = false;
        } catch {
            reverted = true;
        }
        uint256 paid = boost.claimRewards();

        assertTrue(reverted, "second delegation reverted");
        assertEq(paid, 100 ether, "only the remaining boost is paid");
        assertEq(reward.balanceOf(address(boost)), 100 ether, "half the pot stays");
    }
}
