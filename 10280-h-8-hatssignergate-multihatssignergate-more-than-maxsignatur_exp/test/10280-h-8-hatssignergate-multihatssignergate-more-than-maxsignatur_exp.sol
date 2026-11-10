// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, ControlExploit, Token, Safe, HatsSignerGate} from
    "./10280-h-8-hatssignergate-multihatssignergate-more-than-maxsignatur.sol";

contract Finding10280Test is Test {
    function test_exploit_payout_reverts_and_safe_keeps_1000() public {
        Exploit e = new Exploit();
        e.run();

        Token token = e.token();
        Safe safe = e.safe();
        HatsSignerGate gate = e.gate();

        assertEq(token.balanceOf(address(safe)), 1000 ether, "safe still holds 1000");
        assertEq(token.balanceOf(e.PAYEE()), 0, "payee received nothing");
        assertEq(gate.liveValidSigners(), 3, "three valid signers");
        assertEq(gate.maxSigners(), 2, "max signers");
        assertEq(gate.signerCount(), 2, "cache still says 2");
        assertGt(gate.liveValidSigners(), gate.maxSigners(), "live count is over the max");

        console2.log("stuck tokens", token.balanceOf(address(safe)));
        console2.log("valid signers", gate.liveValidSigners());
        console2.log("max signers", gate.maxSigners());
        console2.log("cached signerCount", gate.signerCount());
    }

    function test_control_enforces_max_and_payout_succeeds() public {
        ControlExploit c = new ControlExploit();
        c.run();

        assertEq(c.token().balanceOf(c.PAYEE()), 1000 ether, "payee received 1000");
        assertEq(c.token().balanceOf(address(c.safe())), 0, "safe paid out");
        assertLe(c.gate().liveValidSigners(), c.gate().maxSigners(), "max held");
        assertEq(c.gate().liveValidSigners(), 2, "still two valid signers");

        console2.log("control paid", c.token().balanceOf(c.PAYEE()));
        console2.log("control valid", c.gate().liveValidSigners());
    }
}
