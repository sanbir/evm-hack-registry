// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63222-withdrawers-of-susde-always-incur-a-loss-because-parameters.sol";

contract StrataInvertedParamsTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
