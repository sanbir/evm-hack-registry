// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20, Vault} from
    "./45705-fractionofshares-function-in-teavaultambient-contract-may-ca.sol";

contract Finding45705Test is Test {
    function test_exploit_round_up_mints_an_extra_share() public {
        Exploit e = new Exploit();
        uint256 beforeBal = e.token().balanceOf(address(e));
        e.run();
        assertEq(beforeBal, 100 ether, "deposit capital");
        assertEq(e.token().balanceOf(address(e)), 120 ether, "withdrew 120");
        assertEq(e.token().balanceOf(address(e.vault())), 180 ether, "lps");
        assertEq(e.vault().sharesOf(e.VICTIM()), 3, "victim shares");
    }

    function test_control_round_down_mints_one_share() public {
        ERC20 token = new ERC20();
        Vault vault = new Vault(token, true);
        token.mint(address(vault), 200 ether);
        vault.seed(address(0xBEEF), 3, 200 ether);
        token.mint(address(this), 100 ether);
        token.approve(address(vault), 100 ether);
        uint256 minted = vault.deposit(100 ether);
        assertEq(minted, 1, "floor 1.5 is 1");
        uint256 out = vault.withdraw(minted);
        assertEq(out, 75 ether, "1 of 4 shares of 300");
        assertEq(token.balanceOf(address(this)), 75 ether, "depositor loses the rounding");
        assertEq(token.balanceOf(address(vault)), 225 ether, "lps kept the rounding");
    }
}
