// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    FixedFlow
} from "./60698-unsafe-replyneeded-messaging-mechanism-quantstamp-boba-1-bri.sol";

contract PoC_60698_ReplyNeeded is Test {
    function test_lp_redeems_unreserved_deposit() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.token().balanceOf(address(exp.alice())), 0, "user was not refunded");
        assertEq(exp.token().balanceOf(address(exp)), 180 ether, "LP kept the 100 float plus Alice's 80");
        assertEq(exp.marker().balanceOf(exp.SINK()), 80 ether, "lost amount is 80 tokens");
        (,, bool used) = exp.messenger().queue(1);
        assertTrue(used, "compensation cannot be relayed again");
    }

    function test_control_reserved_deposit_is_returned() public {
        FixedFlow fixedFlow = new FixedFlow();
        fixedFlow.run();

        uint256 stolen = fixedFlow.token().balanceOf(address(fixedFlow)) - 100 ether;
        assertEq(fixedFlow.token().balanceOf(address(fixedFlow.alice())), 80 ether, "user receives the 80 back");
        assertEq(stolen, 0, "LP receives only its own float");
        assertTrue(stolen != 80 ether, "control must not hit the 80 token loss");
    }
}
