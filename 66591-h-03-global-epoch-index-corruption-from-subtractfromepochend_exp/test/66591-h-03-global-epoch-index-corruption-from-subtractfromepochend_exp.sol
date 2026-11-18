// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, RewardToken, EpochLocker, Bob} from
    "./66591-h-03-global-epoch-index-corruption-from-subtractfromepochend.sol";

contract Finding66591Test is Test {
    function test_exploit_alice_takes_200_and_bob_gets_0() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.locker().totalLockedAtEpochEnd(e.OLD_EPOCH()), 100, "aggregate still holds bob");
        assertEq(e.locker().globalEpochCount(), 1, "index dropped the shared epoch");
        assertEq(e.locker().totalSupply(), 100, "supply is half the user locks");
        assertEq(e.aliceGot(), 200, "alice overpaid");
        assertEq(e.bobGot(), 0, "bob underpaid");
        assertEq(e.reward().balanceOf(address(e)), 200, "alice holds the pot");
        assertEq(e.reward().balanceOf(address(e.bob())), 0, "bob holds nothing");
    }

    function test_control_pop_only_when_aggregate_is_zero() public {
        RewardToken reward = new RewardToken();
        EpochLocker locker = new EpochLocker(reward, true);
        Bob bob = new Bob();
        reward.mint(address(this), 200);
        reward.approve(address(locker), 200);
        locker.lock(address(bob), 100, 1000);
        locker.lock(address(this), 100, 1000);
        locker.notifyReward(200);

        locker.extendLock(100, 1000, 2000);
        assertEq(locker.globalEpochCount(), 2, "old epoch stays");
        assertEq(locker.totalSupply(), 200, "supply matches both locks");

        uint256 aliceGot = locker.claim();
        uint256 bobGot = bob.claim(locker);
        assertEq(aliceGot, 100, "alice pro-rata");
        assertEq(bobGot, 100, "bob pro-rata");
    }
}
