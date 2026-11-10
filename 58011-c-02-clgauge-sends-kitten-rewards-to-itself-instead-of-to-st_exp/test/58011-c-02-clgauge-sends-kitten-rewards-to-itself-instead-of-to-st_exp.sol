// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    CLGaugeFixed,
    Exploit,
    Kitten,
    NFP
} from "./58011-c-02-clgauge-sends-kitten-rewards-to-itself-instead-of-to-st.sol";

contract Finding58011Test is Test {
    function test_reward_is_paid_to_the_gauge() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stakerPaid(), 0, "staker claim is 0");
        assertEq(e.gaugeHeld(), 1000 ether, "gauge holds N");
        assertEq(e.kitten().balanceOf(address(e)), 0, "staker balance");
        assertEq(e.kitten().balanceOf(address(e.gauge())), 1000 ether, "gauge balance");
        assertEq(e.gauge().lastPaidTo(), address(e.gauge()), "ownerOf is the gauge");
    }

    function test_control_pays_the_staker() public {
        Kitten kitten = new Kitten();
        NFP nfp = new NFP();
        CLGaugeFixed gauge = new CLGaugeFixed(nfp, kitten);
        address staker = address(this);
        uint256 n = 1000 ether;

        nfp.mint(staker, 1);
        gauge.stake(1);
        kitten.mint(address(gauge), n);
        gauge.notifyReward(1, n);
        assertEq(nfp.ownerOf(1), address(gauge), "stake still parks the nft");

        gauge.getReward(1);

        assertEq(kitten.balanceOf(staker), n, "control pays the staker N");
        assertEq(kitten.balanceOf(address(gauge)), 0, "gauge is left empty");
    }
}
