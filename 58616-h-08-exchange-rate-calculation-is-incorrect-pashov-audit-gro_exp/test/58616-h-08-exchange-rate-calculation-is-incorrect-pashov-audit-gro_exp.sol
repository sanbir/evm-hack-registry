// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58616-h-08-exchange-rate-calculation-is-incorrect-pashov-audit-gro.sol";

contract KinetiqWrongExchangeRateTest is Test {
    function test_exploit_localGlobalMix_wrongDivergentRates() public {
        Exploit e = new Exploit();
        e.run{value: 220 ether}();

        assertEq(e.ratioSM1(), 0.35e18);
        assertEq(e.ratioSM2(), 0.85e18);
        assertEq(e.correctRatio(), 1.1e18);
        assertEq(e.arbProfit(), 37.5 ether);
        assertTrue(e.ratioSM1() != e.ratioSM2());
    }

    receive() external payable {}
}
