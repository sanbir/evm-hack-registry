// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "./18434-read-only-reentrancy-cyfrin-beanstalk-wells-markdown.sol";

contract ReadOnlyReentrancyTest is Test {
    function test_readOnlyReentrancy_inflatesLpPrice_and_drainsLender() public {
        Exploit exploit = new Exploit(); // this test contract is the "attacker"
        Well well = exploit.well();
        MockToken loanToken = exploit.loanToken();
        LendingMock lending = exploit.lending();

        // Sanity: sole LP holds 200e18 LP, price 1.0, lender pool has 1000e18.
        assertEq(well.totalSupply(), 200e18, "setup: LP supply");
        assertEq(well.virtualPrice(), 1e18, "setup: fair price");
        assertEq(loanToken.balanceOf(address(lending)), 1000e18, "setup: lender liquidity");

        // === run the read-only reentrancy attack ===
        exploit.run();

        // 1. Price observed mid-transfer (read-only reentrancy) is inflated 2x.
        assertEq(exploit.fairPriceBefore(), 1e18, "baseline price");
        assertEq(exploit.priceAfter(), 1e18, "post-op price restored");
        assertEq(exploit.priceDuringCallback(), 2e18, "stale-reserve price inflated 2x");
        assertEq(exploit.priceDuringCallback(), 2 * exploit.priceAfter(), "2x relationship");

        // 2. Attacker over-borrowed against the inflated valuation.
        assertEq(exploit.borrowedInCallback(), 200e18, "over-borrow amount");
        assertEq(loanToken.balanceOf(address(this)), 200e18, "attacker got over-borrow");

        // 3. Lender pool left under-collateralized by exactly 100e18.
        uint256 fairCollateral = lending.collateralValue(address(exploit)); // 100e18 at true price
        assertEq(fairCollateral, 100e18, "fair collateral value");
        assertEq(lending.debt(address(exploit)), 200e18, "debt booked");
        assertEq(lending.debt(address(exploit)) - fairCollateral, 100e18, "unbacked loss");
        // pool paid out 200e18 of its 1000e18; only 100e18 of that is backed.
        assertEq(loanToken.balanceOf(address(lending)), 800e18, "pool paid out 200e18");
        assertGt(loanToken.balanceOf(address(this)), fairCollateral, "attacker holds more than fair collateral value");
    }
}
