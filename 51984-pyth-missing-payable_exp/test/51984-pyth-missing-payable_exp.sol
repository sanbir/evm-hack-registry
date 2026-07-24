// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./51984-pyth-missing-payable.sol";

contract Poc51984Test is Test {
    function test_exploit() public {
        vm.deal(address(this), 1 ether);
        Exploit e = new Exploit();
        e.attack{value: 1 wei}();
        assertTrue(e.success(), "reduced model did not reproduce 51984");
    }
}
