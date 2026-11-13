// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Mini,
    Underlying,
    P2pYieldProxyFixed
} from "./56810-locked-residual-token-amounts-on-deposit-mixbytes-none-p2por.sol";

contract Finding56810Test is Test {
    function test_exploit_locks_residual() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.forwarded(), 8_000 ether, "80% forwarded");
        assertEq(e.accounted(), 8_000 ether, "only forwarded amount is tracked");
        assertEq(e.userGot(), 8_000 ether, "user withdraws the accounted 8000");
        assertEq(e.residualLocked(), 2_000 ether, "2000 residual stuck in the proxy");
        assertEq(e.proxyAfterWithdraw(), 2_000 ether, "still stuck after withdraw");
    }

    function test_control_forwards_residual_to_treasury() public {
        Mini token = new Mini();
        Underlying underlying = new Underlying(token);
        address treasury = address(0xBEEF);
        P2pYieldProxyFixed proxy = new P2pYieldProxyFixed(token, underlying, treasury, 8_000);
        token.mint(address(this), 10_000 ether);
        token.approve(address(proxy), 10_000 ether);
        proxy._deposit(10_000 ether);
        uint256 got = proxy.withdrawAll();

        assertEq(got, 8_000 ether, "user receives accounted deposit");
        assertEq(token.balanceOf(address(proxy)), 0, "proxy keeps nothing");
        assertEq(token.balanceOf(treasury), 2_000 ether, "treasury receives the residual");
    }
}
