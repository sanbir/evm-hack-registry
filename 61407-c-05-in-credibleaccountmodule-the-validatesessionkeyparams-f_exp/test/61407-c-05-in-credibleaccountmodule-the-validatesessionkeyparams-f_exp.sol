// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    CredibleAccountModuleFixed,
    PackedUserOperation,
    Token,
    Wallet
} from "./61407-c-05-in-credibleaccountmodule-the-validatesessionkeyparams-f.sol";

contract Finding61407Test is Test {
    function test_exploit_key_spends_past_limit() public {
        Exploit e = new Exploit();
        e.run();

        assertGt(e.N(), e.LIMIT(), "N is above the limit");
        assertEq(e.module().sessionSpent(e.sessionKey()), e.N(), "spent N");
        assertEq(e.token().balanceOf(address(e)), e.N(), "caller received N");
        assertEq(e.token().balanceOf(address(e.wallet())), 0, "wallet emptied");
    }

    function test_control_rejects_params() public {
        Token token = new Token("Glue", "GLUE", 18);
        Wallet wallet = new Wallet();
        CredibleAccountModuleFixed module = new CredibleAccountModuleFixed(token);
        token.mint(address(wallet), 1000 ether);
        wallet.approve(token, address(module), 1000 ether);
        module.enableSession(address(this), address(wallet), 100 ether);

        PackedUserOperation memory op =
            PackedUserOperation({sender: address(wallet), amount: 1000 ether, signature: hex"01"});
        (bool ok, bytes memory ret) = address(module).call(
            abi.encodeCall(module.validateSessionKeyParams, (address(this), op))
        );

        assertFalse(ok, "control must reject the params");
        assertEq(bytes4(ret), CredibleAccountModuleFixed.SessionParamsRejected.selector);
        assertEq(token.balanceOf(address(wallet)), 1000 ether, "N stays in the wallet");
        assertEq(token.balanceOf(address(this)), 0, "caller received nothing");
    }
}
