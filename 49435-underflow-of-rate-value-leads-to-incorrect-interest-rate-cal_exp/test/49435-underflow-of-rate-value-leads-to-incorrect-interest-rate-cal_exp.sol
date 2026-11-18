// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, FundingRateConsumer, OracleFixed} from "./49435-underflow-of-rate-value-leads-to-incorrect-interest-rate-cal.sol";

contract Finding49435Test is Test {
    function test_exploit_negative_rate_charges_full_principal() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.rawRate(), type(uint256).max - 999, "underflow");
        assertEq(e.charged(), 1000 ether, "charged");
        assertEq(e.token().balanceOf(address(e.pool())), 1000 ether, "pool");
        assertEq(e.token().balanceOf(address(e.borrower())), 0, "borrower");
    }

    function test_control_negative_rate_floors_to_zero() public {
        FundingRateConsumer consumer = new FundingRateConsumer();
        OracleFixed oracle = new OracleFixed(consumer);
        address asset = address(0xA55E7);
        oracle.addAsset(asset, "TEST");
        consumer.setRate("TEST", -1000);
        assertEq(oracle.getFundingRate(asset), 0, "floored");
    }
}
