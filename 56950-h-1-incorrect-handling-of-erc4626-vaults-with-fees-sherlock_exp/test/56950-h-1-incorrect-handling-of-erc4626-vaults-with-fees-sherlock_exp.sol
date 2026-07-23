// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./56950-h-1-incorrect-handling-of-erc4626-vaults-with-fees-sherlock.sol";

contract FeeVaultHandlingTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolenFromResidual(), 1 ether, "1e18 fee hole stolen from residual");
        assertLt(e.pool().vaultAssets(), e.pool().valueOf(address(e)), "residual insolvent");
    }
}
