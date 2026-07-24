// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./48953-h-14-users-might-get-less-assets-than-expected-upon-migratio.sol";

contract PoC_48953 is Test {
    function test_migrationPriceManip() public {
        Exploit e = new Exploit();
        e.run();
    }
}
