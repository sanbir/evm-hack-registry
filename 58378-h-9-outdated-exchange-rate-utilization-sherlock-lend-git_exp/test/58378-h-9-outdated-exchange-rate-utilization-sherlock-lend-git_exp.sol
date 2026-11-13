// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, LToken, CoreRouterFixed} from
    "./58378-h-9-outdated-exchange-rate-utilization-sherlock-lend-git.sol";

contract Finding58378Test is Test {
    function test_exploit_stale_exchange_rate_mints_extra_ltokens() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.profit(), 10.05 ether, "profit");
        assertEq(e.booked(), 1005 ether, "booked");
        assertEq(e.victimShort(), 5 ether, "short");
        assertEq(e.token().balanceOf(address(e)), 2020.05 ether, "end");
    }

    function test_control_exchangeRateCurrent_repays_deposit() public {
        Token token = new Token();
        LToken lToken = new LToken(token);
        CoreRouterFixed router = new CoreRouterFixed(token, lToken);
        lToken.seed(address(router), 10000 ether, 10000 ether, 10000 ether);
        token.mint(address(this), 2010 ether);
        token.approve(address(router), 2010 ether);
        router.supply(2010 ether);
        assertEq(router.totalInvestment(address(this)), 1000 ether, "fair shares");
        router.redeem(1000 ether);
        assertEq(token.balanceOf(address(this)), 2010 ether, "no profit");
        assertEq(lToken.balanceOf(address(router)), 10000 ether, "victim intact");
    }
}
