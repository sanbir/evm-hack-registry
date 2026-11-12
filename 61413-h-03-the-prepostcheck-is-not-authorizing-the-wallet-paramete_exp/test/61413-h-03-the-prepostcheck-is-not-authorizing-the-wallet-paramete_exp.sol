// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    CredibleAccountModuleFixed,
    Token,
    WalletA
} from "./61413-h-03-the-prepostcheck-is-not-authorizing-the-wallet-paramete.sol";

contract Finding61413Test is Test {
    function test_exploit_wallet_b_spends_wallet_a() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(address(e) != address(e.walletA()), "caller is not A");
        assertEq(e.token().balanceOf(address(e)), e.N(), "B received 1000 GLUE");
        assertEq(e.token().balanceOf(address(e.walletA())), 0, "A was emptied");
        assertEq(e.module().locked(address(e.walletA())), e.N(), "A was charged N");
    }

    function test_control_checks_the_wallet() public {
        Token token = new Token("Glue", "GLUE", 18);
        WalletA walletA = new WalletA();
        CredibleAccountModuleFixed module = new CredibleAccountModuleFixed(token);
        token.mint(address(walletA), 1000 ether);
        walletA.approve(token, address(module), 1000 ether);
        bytes memory msgData = abi.encode(address(walletA), uint256(1000 ether));

        (bool ok, bytes memory ret) =
            address(module).call(abi.encodeCall(module.preCheck, (address(this), uint256(0), msgData)));

        assertFalse(ok, "control must reject wallet B");
        assertEq(bytes4(ret), CredibleAccountModuleFixed.WalletMismatch.selector);
        assertEq(token.balanceOf(address(walletA)), 1000 ether, "A keeps N");
        assertEq(token.balanceOf(address(this)), 0, "B received nothing");
    }
}
