// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    GluexRouterFixed,
    RouteDescription,
    Token,
    Partner
} from "./61338-h-02-partner-can-receive-zero-share-despite-surplus-shieldif.sol";

contract Finding61338Test is Test {
    function test_exploit_partner_paid_zero_surplus_stays() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.router().lastPartnerShare(), 0, "computed share is 0");
        assertEq(e.token().balanceOf(e.partner()), 0, "partner received 0");
        assertEq(e.token().balanceOf(address(e.router())), e.N(), "1000 GLX sits in the router");
    }

    function test_control_pays_partner_N() public {
        Token token = new Token("GlueX", "GLX", 18);
        GluexRouterFixed router = new GluexRouterFixed(token);
        address partner = address(new Partner());
        token.mint(address(this), 1000 ether);
        token.approve(address(router), 1000 ether);

        router.swap(RouteDescription({partner: partner, partnerSurplusShare: 0, partnerSlippageShare: 0}), 0, 1000 ether);

        assertEq(router.lastPartnerShare(), 1000 ether, "floor pays the full surplus");
        assertEq(token.balanceOf(partner), 1000 ether, "partner received N");
        assertEq(token.balanceOf(address(router)), 0, "router does not keep N");
    }
}
