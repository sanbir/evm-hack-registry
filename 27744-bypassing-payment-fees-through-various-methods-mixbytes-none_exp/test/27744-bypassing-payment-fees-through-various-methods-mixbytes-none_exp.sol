// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./27744-bypassing-payment-fees-through-various-methods-mixbytes-none.sol";

contract FindingTest is Test {
    function test_fee_bypass() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.grossParked(), e.GROSS(), "gross");
        assertEq(e.leftForFee(), 2, "base");
        assertEq(e.feePaid(), 0, "fee");
        assertEq(e.attackerGot(), e.GROSS(), "attacker");
        assertEq(e.feeToGot(), 0, "fee to");
        assertEq(e.controlFee(), e.FAIR_FEE(), "control fee");
        assertEq(e.controlFeeTo(), e.FAIR_FEE(), "control fee to");
        assertEq(e.controlAttacker(), e.GROSS() - e.FAIR_FEE(), "control attacker");
        console2.log("gross");
        console2.log(e.grossParked());
        console2.log("fee base");
        console2.log(e.leftForFee());
        console2.log("fee paid");
        console2.log(e.feePaid());
        console2.log("attacker got");
        console2.log(e.attackerGot());
        console2.log("control fee");
        console2.log(e.controlFee());
        console2.log("control attacker");
        console2.log(e.controlAttacker());
    }
}
