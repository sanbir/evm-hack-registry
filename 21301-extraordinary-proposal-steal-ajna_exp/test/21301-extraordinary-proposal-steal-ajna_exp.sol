// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./21301-extraordinary-proposal-steal-ajna.sol";

contract PoC_21301 is Test {
    function test_arbitrary_account_argument_fabricates_extraordinary_votes() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertEq(exploit.stolen(), 1_000);
        assertEq(exploit.token().balanceOf(address(exploit.grantFund())), 0);
    }
}
