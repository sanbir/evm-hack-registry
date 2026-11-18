// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, BaseGaugeFixed} from
    "./57201-boost-miscalculation-leads-to-excess-distribution-codehawks.sol";

contract Finding57201Test is Test {
    function test_exploit_small_stake_earns_the_gauge_weight() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.received(), 588235294117647050000, "588.235 ether");
        assertEq(e.token().balanceOf(address(e)), 588235294117647050000, "paid");
        assertGt(e.received(), e.fair(), "above the 117.647 fair share");
        assertLt(e.token().balanceOf(address(e.gauge())), e.received(), "whale short");
    }

    function test_control_stake_weight_pays_the_fair_share() public {
        Token token = new Token();
        uint256 reward = 1000 ether;
        uint256 total = 17000 ether;
        uint256 index = (reward * 1e18) / total;
        BaseGaugeFixed gauge = new BaseGaugeFixed(token, index);
        gauge.setStake(address(this), 2000 ether);
        gauge.setStake(address(uint160(0xBEEF)), 10000 ether);
        gauge.setStake(address(uint160(0xCAFE)), 5000 ether);
        token.mint(address(gauge), 1000 ether);

        uint256 got = gauge.claim();
        assertEq(got, 117647058823529410000, "fair 117.647");
        assertEq(token.balanceOf(address(this)), 117647058823529410000, "staker");
        assertEq(token.balanceOf(address(gauge)), 1000 ether - got, "rest remains");
        assertGt(gauge.earned(address(uint160(0xBEEF))), got, "whale still earns more");
    }
}
