// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58615-h-07-exchange-rate-implementation-not-used-in-token-operatio.sol";

contract KinetiqExchangeRateUnusedTest is Test {
    function test_exploit_oneToOneIgnoresRatio_overpays() public {
        Exploit e = new Exploit();
        e.run{value: 120 ether}();

        assertEq(e.ratioAfterSlash(), 0.9e18);
        assertEq(e.fairHype(), 90 ether);
        assertEq(e.paidHype(), 100 ether);
        assertEq(e.protocolLoss(), 10 ether);
    }

    receive() external payable {}
}
