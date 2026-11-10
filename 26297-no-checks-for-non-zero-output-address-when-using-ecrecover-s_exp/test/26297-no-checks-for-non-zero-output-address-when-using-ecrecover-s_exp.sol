// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    AuthenticatorFixed,
    Exploit,
    TermAuth,
    Token,
    Vault
} from "./26297-no-checks-for-non-zero-output-address-when-using-ecrecover-s.sol";

contract Finding26297Test is Test {
    function test_exploit_zero_signature_moves_1000_tokens() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.taken(), 1_000 ether, "1,000 tokens moved");
        assertEq(e.token().balanceOf(address(0x1111111111111111111111111111111111111111)), 1_000 ether, "attacker balance");
        assertEq(e.token().balanceOf(address(e.vault())), 0, "vault drained");
    }

    function test_control_rejects_address_zero() public {
        Token token = new Token();
        AuthenticatorFixed auth = new AuthenticatorFixed();
        Vault vault = new Vault(token, auth);
        token.mint(address(vault), 1_000 ether);

        bytes memory sig = new bytes(65);
        TermAuth memory termAuth = TermAuth({user: address(0), nonce: 1, signature: sig});

        vm.expectRevert(AuthenticatorFixed.InvalidSignature.selector);
        vault.withdraw(termAuth, address(this), 1_000 ether);

        assertEq(token.balanceOf(address(vault)), 1_000 ether, "tokens stayed");
        assertEq(token.balanceOf(address(this)), 0, "caller received nothing");
    }
}
