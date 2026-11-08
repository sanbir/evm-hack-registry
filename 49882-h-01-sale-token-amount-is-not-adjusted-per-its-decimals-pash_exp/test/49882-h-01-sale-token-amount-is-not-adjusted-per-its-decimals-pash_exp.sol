// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Exploit, MockToken, PublicSale} from "./49882-h-01-sale-token-amount-is-not-adjusted-per-its-decimals-pash.sol";

contract DefiAppSaleDecimalsTest is Test {
    function test_exploit_buyer_receives_1e11_instead_of_1e23() public {
        Exploit e = new Exploit();
        e.run();

        uint256 got = e.home().balanceOf(address(e));
        uint256 spent = e.usdc().balanceOf(address(e.sale()));
        uint256 fair = e.sale()._computeTokensFixed(e.PAID(), e.sale().PRICE());
        console.log("USDC paid (6 decimals)", spent);
        console.log("HOME received", got);
        console.log("HOME that 1000 USDC should buy", fair);
        assertEq(spent, 1000 * 1e6, "buyer pays 1000 USDC");
        assertEq(got, 1e11, "buyer receives 1e11");
        assertEq(fair, 100000 ether, "fair amount is 1e23");
        assertEq(fair / got, 1e12, "short by 1e12");
    }

    function test_control_scaling_by_1e12_pays_the_fair_amount() public {
        MockToken usdc = new MockToken("USDC", "USDC", 6);
        MockToken home = new MockToken("HOME", "HOME", 18);
        PublicSale sale = new PublicSale(usdc, home);
        uint256 fair = 100000 ether;
        home.mint(address(sale), fair);
        usdc.mint(address(this), 1000 * 1e6);
        usdc.approve(address(sale), 1000 * 1e6);
        sale.depositUSDCFixed(1000 * 1e6);
        assertEq(home.balanceOf(address(this)), fair, "fix delivers 1e23 HOME");
        assertEq(usdc.balanceOf(address(sale)), 1000 * 1e6, "same 1000 USDC paid");
    }
}
