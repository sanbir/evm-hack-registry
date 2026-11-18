// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, MockUSDC} from "./55092-h-1-anyone-who-is-approving-blueprintv5-contract-to-spend-er.sol";

contract FixedPayment {
    function payFromCaller(MockUSDC token, uint256 amount, address to) external {
        require(to != msg.sender, "Cannot transfer to self address");
        require(to != address(0), "Invalid to address");
        require(amount > 0, "Amount must be greater than 0");
        require(token.transferFrom(msg.sender, to, amount), "pull");
    }
}

contract Finding55092Test is Test {
    function test_exploit_public_pay_drains_approval() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.usdc().balanceOf(address(e.victim())), 0, "victim");
        assertEq(e.usdc().balanceOf(address(e)), 1000 ether, "attacker");
    }

    function test_control_caller_bound_pay_cannot_choose_victim() public {
        Exploit e = new Exploit();
        FixedPayment fixedPay = new FixedPayment();
        MockUSDC usdc = e.usdc();
        (bool ok,) = address(fixedPay).call(
            abi.encodeWithSignature("payFromCaller(address,uint256,address)", address(usdc), 1000 ether, address(0xBEEF))
        );
        assertFalse(ok, "caller-bound pay must not pull a third party");
        assertEq(usdc.balanceOf(address(e.victim())), 1000 ether, "victim intact");
    }
}
