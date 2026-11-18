// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, TokenManagerFixed, CapitalPool, MockUSDC} from
    "./38060-tokenmanager-unlimited-withdraw-codehawks-tadle-git.sol";

contract Finding38060Test is Test {
    function test_withdraw_drains_capital_pool() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "attacker took the pool");
        assertEq(e.token().balanceOf(address(e.pool())), 0, "pool empty");
        assertEq(e.manager().userTokenBalanceMap(address(e), address(e.token()), 0), 100 ether, "credit still 100");
    }

    function test_control_zeroing_the_credit_pays_once() public {
        MockUSDC token = new MockUSDC();
        CapitalPool pool = new CapitalPool();
        TokenManagerFixed manager = new TokenManagerFixed(pool);
        token.mint(address(pool), 1000 ether);
        pool.approveToken(token, address(manager));
        manager.creditRefund(address(this), address(token), 100 ether);
        manager.withdrawOnce(address(token), 0);
        manager.withdrawOnce(address(token), 0);
        assertEq(token.balanceOf(address(this)), 100 ether, "paid once");
        assertEq(token.balanceOf(address(pool)), 900 ether, "rest stays");
    }
}
