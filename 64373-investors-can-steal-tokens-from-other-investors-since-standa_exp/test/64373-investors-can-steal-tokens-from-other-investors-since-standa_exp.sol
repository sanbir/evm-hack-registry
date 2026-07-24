// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./64373-investors-can-steal-tokens-from-other-investors-since-standa.sol";

contract StandardTokenApprovalBypassTest is Test {
    function test_unapprovedInvestorCanSteal() external {
        Exploit exploit = new Exploit();
        exploit.run();
        assertEq(exploit.dsToken().balanceOf(address(exploit)), 100);
        assertEq(exploit.dsToken().allowance(exploit.VICTIM(), address(exploit)), 0);
    }
}
