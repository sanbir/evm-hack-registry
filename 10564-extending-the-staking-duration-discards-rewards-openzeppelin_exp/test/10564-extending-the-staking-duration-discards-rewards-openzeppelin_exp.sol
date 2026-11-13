// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Ogv,
    RewardsSource,
    OgvStaking,
    Alice
} from "./10564-extending-the-staking-duration-discards-rewards-openzeppelin.sol";

contract Finding10564Test is Test {
    function test_exploit_extend_discards_50() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.ogv().balanceOf(address(e)), 0, "bob received nothing");
        assertEq(e.LOST(), 50 ether, "50 discarded");
    }

    function test_control_collect_before_extend_pays_50() public {
        Ogv ogv = new Ogv();
        RewardsSource source = new RewardsSource(ogv);
        OgvStaking staking = new OgvStaking(ogv, source);
        Alice alice = new Alice(staking);
        ogv.mint(address(this), 100 ether);
        staking.stake(100 ether, 7 days);
        ogv.mint(address(alice), 100 ether);
        alice.stake(100 ether, 7 days);
        ogv.mint(address(this), 100 ether);
        source.fund(100 ether);
        alice.collect();
        staking.collectRewards();
        staking.extend(0, 14 days);
        assertEq(ogv.balanceOf(address(this)), 50 ether, "control paid 50");
    }
}
