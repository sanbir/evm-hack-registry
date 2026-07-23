// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./62107-h-2-redeemqueue-accounting-mismatch-between-batch-creation-a.sol";

contract Mellow62107Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.batch0Shares(), 10_000_000, "batch only first user");
        assertEq(e.user2Received(), 10_000_000, "user2 drained batch");
        assertEq(e.user1Received(), 0, "user1 locked out");
    }
}
