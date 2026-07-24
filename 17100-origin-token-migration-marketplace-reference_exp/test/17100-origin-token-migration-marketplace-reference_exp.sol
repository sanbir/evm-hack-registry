// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./17100-origin-token-migration-marketplace-reference.sol";

contract PoC_17100 is Test {
    function test_migration_pauses_old_marketplace_currency_and_locks_funds() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.finalizeBlocked());
        assertFalse(exploit.marketplace().completed());
        assertEq(exploit.marketplace().listingDeposit(), 1_000);
        assertEq(exploit.marketplace().offerAmount(), 500);
        assertEq(address(exploit.marketplace().currency()), address(exploit.oldToken()));
        assertTrue(exploit.oldToken().paused());
    }
}
