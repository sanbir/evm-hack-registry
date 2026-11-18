// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./45889-converttoassets-is-receiving-assets-decimals-instead-of-shar.sol";

contract FindingTest is Test {
    function test_exploit() public {
        
        Exploit e = new Exploit();
        e.run();
        assertEq(e.feeTaken(), 0);
        assertEq(e.redeemed(), 2_000_000_000);
        assertEq(e.controlFeePaid(), 100_000_000);
        assertEq(e.controlRedeemed(), 1_900_000_000);
    }
}
