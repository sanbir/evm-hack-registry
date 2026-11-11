// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Marketing,
    MockAdmin,
    MockStaking,
    MockUSDC,
    TokenSaleFixed
} from "./31190-h-1-tax-refund-is-calculated-based-on-the-wrong-amount-sherl.sol";

contract Finding31190Test is Test {
    uint256 internal constant DEPOSIT = 1000 ether;
    uint256 internal constant LEFT = 500 ether;
    uint256 internal constant TAX_PAID = 100 ether;
    uint256 internal constant PAID_REFUND = 50 ether;
    uint256 internal constant FAIR_REFUND = 90 ether;
    uint256 internal constant SHORTFALL = 40 ether;

    function test_exploit_refund_uses_only_left() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paidRefund(), PAID_REFUND, "paid 50 USDC");
        assertEq(e.fairRefund(), FAIR_REFUND, "fair 90 USDC");
        assertEq(e.shortfall(), SHORTFALL, "short 40 USDC");
        assertEq(e.retained(), TAX_PAID - PAID_REFUND, "marketing keeps 50");
        assertEq(e.usdc().balanceOf(address(e.marketing())), 50 ether, "50 USDC still in marketing");
        assertEq(e.usdc().balanceOf(address(e)), LEFT + PAID_REFUND, "investor got left plus the short refund");

        (uint128 amount, uint120 share, bool claimed, uint256 taxAmount) = e.sale().stakes(address(e));
        assertEq(amount, DEPOSIT, "deposit");
        assertEq(share, uint120(LEFT), "share is half");
        assertEq(taxAmount, TAX_PAID, "tax charged on the full deposit");
        assertTrue(claimed, "claim completed");
    }

    function test_control_refunds_left_plus_tax_free() public {
        MockUSDC usdc = new MockUSDC();
        MockAdmin admin = new MockAdmin();
        MockStaking staking = new MockStaking();
        Marketing marketing = new Marketing();
        TokenSaleFixed sale = new TokenSaleFixed(address(usdc), address(admin), address(staking), address(marketing));

        usdc.mint(address(this), TAX_PAID + LEFT);
        usdc.approve(address(sale), type(uint256).max);
        sale.seedOversold(address(this), uint128(DEPOSIT), TAX_PAID, LEFT);
        assertEq(usdc.balanceOf(address(marketing)), TAX_PAID, "tax seated");

        sale.claim();

        assertEq(usdc.balanceOf(address(this)), LEFT + FAIR_REFUND, "control pays 90 USDC tax on top of 500 USDC left");
        assertEq(usdc.balanceOf(address(marketing)), TAX_PAID - FAIR_REFUND, "marketing keeps the fair 10 USDC");
        (,, bool claimed,) = sale.stakes(address(this));
        assertTrue(claimed, "claim recorded");
    }
}
