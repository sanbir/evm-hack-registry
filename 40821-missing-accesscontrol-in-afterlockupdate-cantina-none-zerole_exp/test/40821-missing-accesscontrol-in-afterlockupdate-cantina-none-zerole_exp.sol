// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./40821-missing-accesscontrol-in-afterlockupdate-cantina-none-zerole.sol";

contract AfterLockACTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
