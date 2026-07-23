// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./55704-h-02-sqrt-function-silently-reverts-the-entire-control-flow.sol";

contract H02Exp is Test {
    function test_h02_sqrt_zero_silent_stop() public {
        Exploit e = new Exploit();
        e.run();

        VulnerableOracle oracle = e.oracle();
        // Control: non-zero settles.
        oracle.reset();
        oracle.computeAndSettle(1);
        assertTrue(oracle.settled(), "non-zero settles");

        // Bug: zero stops without settling.
        oracle.reset();
        (bool ok,) = address(oracle).call(abi.encodeWithSelector(VulnerableOracle.computeAndSettle.selector, uint256(0)));
        assertTrue(ok, "stop is not a revert");
        assertFalse(oracle.settled(), "settlement skipped");
    }
}
