// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit, OutToken, Treasury, Partner, GluexRouter} from "./61337-h-01-protocol-can-receive-zero-shares-despite-surplus-shield.sol";
contract Finding61337Test is Test {
    function test_exploit_treasury_receives_zero() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e.treasury())), 0);
        assertEq(e.token().balanceOf(address(e.partner())), 100 ether);
        assertEq(e.router().lastProtocolShare(), 0);
        assertEq(e.router().lastSurplus(), 100 ether);
    }
    function test_control_minimum_slippage_share_pays_treasury() public {
        OutToken token = new OutToken();
        Treasury treasury = new Treasury();
        Partner partner = new Partner();
        GluexRouter router = new GluexRouter(token, address(treasury), address(partner));
        token.mint(address(router), 300 ether);
        uint256 protocolShare = router.settle(100 ether, 200 ether, 0, 0, 1000);
        assertEq(protocolShare, 120 ether);
        assertEq(token.balanceOf(address(treasury)), 120 ether);
    }
}
