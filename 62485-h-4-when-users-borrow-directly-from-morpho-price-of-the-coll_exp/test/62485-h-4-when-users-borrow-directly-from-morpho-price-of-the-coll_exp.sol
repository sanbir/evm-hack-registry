// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./62485-h-4-when-users-borrow-directly-from-morpho-price-of-the-coll.sol";

contract MorphoMispriceTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
