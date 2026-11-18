// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Erc20, Holder, BoostControllerFixed} from
    "./57146-delegation-boost-not-usable-by-delegatees-codehawks-regnum-a.sol";

contract Finding57146Test is Test {
    function test_exploit_delegatee_receives_dust_and_other_takes_the_pot() public {
        Exploit e = new Exploit();
        e.run();

        assertLt(e.reward().balanceOf(address(e.delegatee())), 1 ether, "delegatee dust");
        assertGt(e.reward().balanceOf(address(e.other())), 999 ether, "other overpaid");
        assertEq(
            e.reward().balanceOf(address(e.delegatee())) + e.reward().balanceOf(address(e.other())),
            1000 ether,
            "pot paid out"
        );
    }

    function test_control_delegation_splits_the_pot() public {
        Erc20 reward = new Erc20();
        Erc20 ve = new Erc20();
        address pool = address(uint160(0xBEEF));
        BoostControllerFixed fixedBoost = new BoostControllerFixed(ve, reward, pool);
        Holder delegatee = new Holder();
        Holder other = new Holder();
        ve.mint(address(this), 1_000_000 ether);
        ve.mint(address(other), 1_000_000 ether);
        fixedBoost.delegateBoost(address(delegatee), 1_000_000 ether, 7 days);
        reward.mint(address(fixedBoost), 1000 ether);
        fixedBoost.settle(pool, address(delegatee), address(other));

        assertEq(reward.balanceOf(address(delegatee)), 500 ether, "delegatee half");
        assertEq(reward.balanceOf(address(other)), 500 ether, "other half");
    }
}
