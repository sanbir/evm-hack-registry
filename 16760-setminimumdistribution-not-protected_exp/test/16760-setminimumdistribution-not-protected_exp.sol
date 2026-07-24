// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./16760-setminimumdistribution-not-protected.sol";

contract PoC_16760 is Test {
    function test_untrusted_user_can_grow_distribution_list() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertEq(exploit.inserted(), 33);
        assertEq(exploit.iterations(), 33);
    }
}
