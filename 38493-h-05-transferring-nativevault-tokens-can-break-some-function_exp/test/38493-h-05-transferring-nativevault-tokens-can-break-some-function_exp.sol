// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, NativeVault} from
    "./38493-h-05-transferring-nativevault-tokens-can-break-some-function.sol";

contract Finding38493Test is Test {
    address internal constant BUYER = 0x2222222222222222222222222222222222222222;
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_transfer_then_slash_takes_the_backing() public {
        Exploit e = new Exploit();
        e.run{value: 100 ether}();
        assertEq(address(e.vault()).balance, 0, "vault emptied");
        assertEq(e.vault().balanceOf(BUYER), 100 ether, "buyer still holds the shares");
        assertEq(e.vault().convertToAssets(100 ether), 0, "shares have no backing");
        assertEq(e.marker().balanceOf(SINK), 100 ether, "100 mis-slashed");
    }

    function test_control_slash_is_zero_while_the_owner_holds_the_shares() public {
        NativeVault vault = new NativeVault();
        vault.deposit{value: 100 ether}(address(this));
        uint256 charged = vault.slash(address(this));
        assertEq(charged, 0, "no slash while shares match the restake");
        assertEq(address(vault).balance, 100 ether, "backing stays");
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 100 ether, "shares still worth 100");
    }

    receive() external payable {}
}
