// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./15980-h-07-user-can-pass-auction-recovery-health-check-easily-with.sol";

contract PoC_15980 is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertFalse(e.pool().auctionActive(address(e)), "auction must remain cancelled");
        assertEq(e.pool().collateralOf(address(e)), e.POSITION_COLLATERAL());
        assertEq(e.pool().debtOf(address(e)), e.POSITION_DEBT());
    }
}
