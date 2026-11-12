// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    CredibleAccountModuleFixed,
    Multiplexer,
    Token,
    Wallet
} from "./61414-h-04-modularetherspotwallet-can-get-dosed-from-uninstalling.sol";

contract Finding61414Test is Test {
    function test_exploit_execute_reverts_and_N_stays() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.module().validatorInitialized(address(e.wallet())), "validator stuck");
        assertTrue(e.module().hookInitialized(address(e.wallet())), "hook stuck");
        assertTrue(e.module().activeHook(address(e.wallet())) != address(e.multiplexer()), "mux gone");
        assertEq(e.token().balanceOf(address(e.wallet())), e.N(), "1000 GLUE stays in the wallet");
        assertEq(e.token().balanceOf(address(e)), 0, "caller was not paid");
    }

    function test_control_uninstalls_and_execute_pays() public {
        Token token = new Token("Glue", "GLUE", 18);
        Multiplexer multiplexer = new Multiplexer();
        CredibleAccountModuleFixed module = new CredibleAccountModuleFixed(address(multiplexer));
        Wallet wallet = new Wallet(token, address(module));
        token.mint(address(wallet), 1000 ether);
        module.setMultiplexer(address(wallet));
        module.onInstall(address(wallet), 1);

        (bool hookOk,) = address(module).call(abi.encodeCall(module.onInstall, (address(wallet), uint256(2))));
        assertFalse(hookOk, "hook install must be rejected");

        module.onUninstall(address(wallet), 1);
        assertFalse(module.validatorInitialized(address(wallet)), "validator uninstalled");

        bool paid = wallet.execute(address(this), 1000 ether);
        assertTrue(paid, "execute works");
        assertEq(token.balanceOf(address(this)), 1000 ether, "caller received N");
        assertEq(token.balanceOf(address(wallet)), 0, "wallet paid N");
    }
}
