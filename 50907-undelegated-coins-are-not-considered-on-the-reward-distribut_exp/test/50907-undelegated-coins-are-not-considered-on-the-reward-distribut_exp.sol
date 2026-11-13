// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./50907-undelegated-coins-are-not-considered-on-the-reward-distribut.sol";

contract Finding50907Test is Test {
    function test_undelegated_coins_are_omitted_from_the_reward() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 100 ether, "paid");
        assertEq(e.controlPaid(), 150 ether, "control");
        assertEq(e.shortfall(), 50 ether, "gap");

        console2.log("miner paid");
        console2.log(e.paid());
        console2.log("control paid");
        console2.log(e.controlPaid());
        console2.log("shortfall");
        console2.log(e.shortfall());
    }
}
