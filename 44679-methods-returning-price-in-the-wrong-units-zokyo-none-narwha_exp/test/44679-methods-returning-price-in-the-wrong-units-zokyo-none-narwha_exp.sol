// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockCredit,
    TradingVaultV2Fixed
} from "./44679-methods-returning-price-in-the-wrong-units-zokyo-none-narwha.sol";

contract Finding44679Test is Test {
    function test_exploit_borrow_uses_six_decimal_price() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.price(), 1e6, "price is 1e6");
        assertEq(e.fairPrice(), 1e18, "fair price is 1e18");
        assertEq(e.paid(), 1e6, "borrow pays 1e6");
        assertEq(e.unpaid(), 1e18 - 1e6, "shortfall stays in the vault");
        assertEq(e.credit().balanceOf(address(e)), 1e6, "borrower balance");
        assertEq(e.credit().balanceOf(address(e.vault())), 1e18 - 1e6, "vault balance");
    }

    function test_control_converts_price_units() public {
        MockCredit credit = new MockCredit();
        TradingVaultV2Fixed vault = new TradingVaultV2Fixed(address(credit));
        vault.seed(1e18, 1e6);
        uint256 raw = vault.getPricePerFullShare();
        uint256 fair = raw * (10 ** (18 - vault.USDT_DECIMALS()));
        assertEq(raw, 1e6, "raw price");
        assertEq(fair, 1e18, "converted price");
        credit.mint(address(vault), 1e18);
        vault.borrow(1e18);
        assertEq(credit.balanceOf(address(this)), 1e18, "control pays 1e18");
        assertEq(credit.balanceOf(address(vault)), 0, "vault emptied");
    }
}
