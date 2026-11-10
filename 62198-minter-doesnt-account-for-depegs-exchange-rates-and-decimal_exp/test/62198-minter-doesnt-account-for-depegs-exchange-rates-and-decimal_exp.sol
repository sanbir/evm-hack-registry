// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    IMintableERC20,
    IERC20,
    MinterFixed,
    Token
} from "./62198-minter-doesnt-account-for-depegs-exchange-rates-and-decimal.sol";

contract Finding62198Test is Test {
    function test_exploit_mints_raw_amount() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.minted(), 1_000_000, "minted raw hBTC");
        assertEq(e.fair(), 1_000, "fair hBTC");
        assertEq(e.hil().balanceOf(address(e)), 1_000_000, "caller holds the raw mint");
        assertEq(e.base().balanceOf(address(e.minter())), 1_000_000, "minter took 1 USDC");
    }

    function test_control_uses_the_right_scale() public {
        Token base = new Token("USD Coin", "USDC", 6);
        Token hil = new Token("Hil BTC", "hBTC", 8);
        MinterFixed minter = new MinterFixed(IERC20(address(base)), IMintableERC20(address(hil)));
        minter.setWhitelisted(address(this), true);
        base.mint(address(this), 1_000_000);
        base.approve(address(minter), 1_000_000);
        minter.mint(address(this), 1_000_000);

        assertEq(hil.balanceOf(address(this)), 1_000, "control mints the fair amount");
        assertEq(base.balanceOf(address(minter)), 1_000_000, "same 1 USDC deposited");
    }
}
