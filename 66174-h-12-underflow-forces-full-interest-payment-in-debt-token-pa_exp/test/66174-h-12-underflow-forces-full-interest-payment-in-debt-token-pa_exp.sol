// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, DebtTokenFixed} from "./66174-h-12-underflow-forces-full-interest-payment-in-debt-token-pa.sol";

contract Finding66174Test is Test {
    function test_exploit_partial_interest_payment_reverts() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.partialAccepted(), false, "50 payment reverted");
        assertEq(e.interestAfterPartial(), 100 ether, "interest stayed 100");
        assertEq(e.interestAfterFull(), 0, "full payment cleared it");
        assertEq(e.paid(), 100 ether, "paid 100");
    }

    function test_control_partial_payment_reduces_interest() public {
        Token asset = new Token("debt");
        DebtTokenFixed debt = new DebtTokenFixed(asset);
        asset.mint(address(this), 50 ether);
        asset.approve(address(debt), 50 ether);
        debt.burn(50 ether);
        assertEq(debt.scaledBalanceIncrease(), 50 ether, "interest falls to 50");
        assertEq(debt.scaledBalance(), 1000 ether, "principal unchanged");
        assertEq(asset.balanceOf(address(debt)), 50 ether, "only 50 was pulled");
    }
}
