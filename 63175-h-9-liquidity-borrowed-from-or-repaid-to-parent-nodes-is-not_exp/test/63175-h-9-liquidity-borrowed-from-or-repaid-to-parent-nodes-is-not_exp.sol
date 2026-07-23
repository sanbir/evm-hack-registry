// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63175-h-9-liquidity-borrowed-from-or-repaid-to-parent-nodes-is-not.sol";

contract AmmplifyParentBorrowTest is Test {
    function test_exploit_siblingNotSettled() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.accountingBroken(), "broken");
        assertGt(uint256(int256(e.siblingPreBorrow())), 0);
        assertEq(e.siblingPoolLiq(), 0);
    }
}
