// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, Voter, Minter, Gauge} from "./41460-h-01-killgauge-will-lead-to-wrong-calculation-of-emission-co.sol";

contract Finding41460Test is Test {
    function test_exploit_last_gauge_paid_zero() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.firstReceived(), 40 ether, "first gauge paid 40");
        assertEq(e.lastPaid(), false, "last distribute reverted");
        assertEq(e.lastGauge().paid(), 0, "last gauge paid 0");
        assertEq(e.asset().balanceOf(address(e.minter())), 40 ether, "40 returned");
    }

    function test_control_equal_gauges_each_receive_fair_share() public {
        Token asset = new Token("FNX");
        Voter voter = new Voter(asset, address(this));
        Minter minter = new Minter();
        voter.setMinter(address(minter));
        Gauge a = new Gauge(asset, address(voter));
        Gauge b = new Gauge(asset, address(voter));
        Gauge c = new Gauge(asset, address(voter));
        voter.seed(address(a), address(uint160(1)), 500 ether);
        voter.seed(address(b), address(uint160(2)), 500 ether);
        voter.seed(address(c), address(uint160(3)), 500 ether);
        asset.mint(address(minter), 80 ether);
        voter.rollEpoch();
        minter.notify(voter, asset, 80 ether);
        voter.distributeOne(address(a));
        voter.distributeOne(address(b));
        voter.distributeOne(address(c));
        assertEq(a.paid(), 26666666666666666500, "a fair");
        assertEq(b.paid(), 26666666666666666500, "b fair");
        assertEq(c.paid(), 26666666666666666500, "c fair");
    }
}
