// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Marketing,
    MockAdmin,
    MockStaking,
    MockUSDC,
    TokenSale,
    TokenSaleFixed
} from "./31191-h-2-if-token-does-not-oversell-users-cannot-claim-tax-refund.sol";

contract Finding31191Test is Test {
    uint256 internal constant DEPOSIT = 1000 ether;
    uint256 internal constant TAX = 100 ether;

    function test_exploit_tax_refund_stuck() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.DEPOSIT(), DEPOSIT, "deposit scale");
        assertEq(e.TAX_REFUND(), TAX, "refund scale");
        assertTrue(e.claimReverted(), "claim reverted");
        assertEq(e.stuckRefund(), TAX, "100 USDC tax seated in marketing");
        assertEq(e.userReceived(), 0, "investor received nothing");
        assertEq(e.usdc().balanceOf(address(e.marketing())), TAX, "100 USDC refund stuck");
        assertEq(e.usdc().balanceOf(address(e)), 0, "exploit holds no USDC");

        (uint128 amount,, bool claimed, uint256 taxAmount) = e.sale().stakes(address(e));
        assertEq(amount, DEPOSIT, "full deposit still allocated");
        assertEq(taxAmount, TAX, "tax still owed");
        assertFalse(claimed, "claim did not complete");
    }

    function test_control_pays_the_refund() public {
        MockUSDC usdc = new MockUSDC();
        MockAdmin admin = new MockAdmin();
        MockStaking staking = new MockStaking();
        Marketing marketing = new Marketing();
        TokenSaleFixed sale = new TokenSaleFixed(address(usdc), address(admin), address(staking), address(marketing));

        usdc.mint(address(this), TAX);
        usdc.approve(address(sale), type(uint256).max);
        sale.seedUnsold(address(this), uint128(DEPOSIT), TAX);
        assertEq(usdc.balanceOf(address(marketing)), TAX, "tax seated");
        assertEq(usdc.balanceOf(address(this)), 0, "investor paid the tax");

        sale.claim();

        assertEq(usdc.balanceOf(address(this)), TAX, "control pays 100 USDC");
        assertEq(usdc.balanceOf(address(marketing)), 0, "marketing wallet emptied");
        (,, bool claimed,) = sale.stakes(address(this));
        assertTrue(claimed, "claim recorded");
    }
}
