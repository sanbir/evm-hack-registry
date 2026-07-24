// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./19837-h-01-wrong-fee-calculation-after-totalsupply-was-0-code4rena.sol";

contract PoC_19837 is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertGt(e.basket().balanceOf(e.FEE_RECIPIENT()), 80_000);
        assertGt(e.basket().totalSupply(), e.RESUPPLY() * 2);
    }
}
