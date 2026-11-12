// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Usd, PricingFixed, Precision, FeeReceiver, Pool} from
    "./18638-h-12-fee-receiver-is-given-twice-the-amount-of-borrow-fees-i.sol";

contract Finding18638Test is Test {
    function test_exploit_receiver_paid_twice() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.pricing().paidToReceiver(), 600e18, "paid 600");
        assertEq(e.pricing().fairToReceiver(), 300e18, "fair 300");
        assertEq(e.token().balanceOf(address(e.receiver())), 600e18, "receiver balance");
        assertEq(e.pricing().totalNetCostAmount(), 1_300e18, "charged 1300");
        assertEq(e.pricing().fairNetCostAmount(), 1_000e18, "fair cost 1000");
        assertEq(e.pricing().paidToReceiver(), 2 * e.pricing().fairToReceiver(), "twice");
        assertEq(e.token().balanceOf(address(e.pool())), 700e18, "pool 700");
        assertEq(e.token().balanceOf(address(e.pricing())), 0, "deposit consumed");
        assertEq(Precision.applyFactor(1_000e18, 3 * 10 ** 29), 300e18, "30 percent");
    }

    function test_control_pays_once() public {
        Usd token = new Usd();
        PricingFixed fixedPricing = new PricingFixed(token);
        FeeReceiver receiver = new FeeReceiver();
        Pool pool = new Pool();
        fixedPricing.seed(address(this), address(receiver), address(pool));
        fixedPricing.settle();

        assertEq(fixedPricing.paidToReceiver(), 300e18, "control pays 300");
        assertEq(fixedPricing.fairToReceiver(), 300e18, "fair matches");
        assertEq(fixedPricing.totalNetCostAmount(), 1_000e18, "control charges 1000");
        assertEq(token.balanceOf(address(receiver)), 300e18, "receiver once");
        assertEq(token.balanceOf(address(pool)), 700e18, "pool once");
        assertEq(token.balanceOf(address(fixedPricing)), 300e18, "trader keeps 300");
    }
}
