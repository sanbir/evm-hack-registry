// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./53524-toke-14-incorrect-streaming-fee-share-calculation-hexens-non.sol";

contract Finding53524Test is Test {
    function test_total_assets_fee_pays_the_sink_99999999999999999999() public {
        Exploit e = new Exploit();
        e.run();
        console2.log("paid", e.paid());
        console2.log("shares", e.sharesMinted());
        assertEq(e.paid(), 99999999999999999999, "paid");
        assertEq(e.asset().balanceOf(e.SINK()), 99999999999999999999, "sink");
    }

    function test_control_profit_fee_pays_10() public {
        Exploit e = new Exploit();
        e.runControl();
        console2.log("control paid", e.controlPaid());
        assertEq(e.controlPaid(), 10 ether, "fair");
        assertEq(e.asset().balanceOf(e.SINK()), 10 ether, "sink");
    }
}
