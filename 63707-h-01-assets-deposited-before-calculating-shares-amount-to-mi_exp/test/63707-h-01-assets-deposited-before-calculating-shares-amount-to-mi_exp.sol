// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63707-h-01-assets-deposited-before-calculating-shares-amount-to-mi.sol";

contract HybraSharesOrderTest is Test {
    function test_alice_mints_fewer_shares_due_to_deposit_before_calc() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.bobShares(), 100e18, "bob shares");
        assertEq(e.aliceShares(), 50e18, "alice under-minted to 50");
        assertLt(e.aliceShares(), e.bobShares(), "alice < bob");
    }
}
