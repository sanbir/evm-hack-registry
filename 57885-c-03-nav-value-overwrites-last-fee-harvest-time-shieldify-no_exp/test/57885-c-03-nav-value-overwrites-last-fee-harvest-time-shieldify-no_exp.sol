// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, FeeToken, Fund} from "./57885-c-03-nav-value-overwrites-last-fee-harvest-time-shieldify-no.sol";

contract Finding57885Test is Test {
    function test_nav_write_skips_the_100_ether_fee() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.slotAfter(), 1_000_000 ether, "slot holds the NAV");
        assertTrue(e.harvestReverted(), "harvest reverts");
        assertEq(e.skipped(), 100 ether, "100 skipped");
        assertEq(e.fund().feesCollected(), 0, "nothing collected");
        assertEq(e.token().balanceOf(address(e.fund())), 100 ether, "fee still on the fund");
    }

    function test_control_preserves_the_timestamp_and_pays_100() public {
        FeeToken token = new FeeToken();
        Fund fund = new Fund(token, address(this), true);
        token.mint(address(fund), 100 ether);
        assertTrue(fund._timeKey() != fund._navKey(), "keys differ");

        fund.setVaultState(1_000_000 ether, 0);
        assertEq(fund.store(fund._timeKey()), 0, "timestamp preserved");
        assertEq(fund.store(fund._navKey()), 1_000_000 ether, "NAV stored separately");

        uint256 paid = fund.harvestPerformanceFee();
        assertEq(paid, 100 ether, "control pays 100");
        assertEq(token.balanceOf(address(this)), 100 ether, "dao received 100");
        assertEq(token.balanceOf(address(fund)), 0, "fund paid the fee");
        assertEq(fund.store(fund._timeKey()), 0, "timestamp still intact");
    }
}
