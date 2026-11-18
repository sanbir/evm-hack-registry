// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, CoreRouter} from "./58371-h-2-protocol-rewards-tokens-permanently-stuck-sherlock-lend.sol";
contract Finding58371Test is Test {
    function test_protocol_reward_is_stuck() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stuck(), 28e18);
        assertEq(e.col().balanceOf(address(e.router())), 28e18);
        assertEq(e.col().balanceOf(address(e)), 972e18);
        assertEq(e.store().totalInvestment(address(e), e.LTOKEN()), 0);
    }
    function test_control_stuck_reward_cannot_be_redeemed() public {
        Exploit e = new Exploit();
        e.run();
        CoreRouter router = e.router();
        address ltoken = e.LTOKEN();
        vm.expectRevert("Insufficient balance");
        router.redeem(28e18, ltoken);
    }
}
