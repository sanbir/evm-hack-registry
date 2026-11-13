// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ValueToken, UFarmPoolFixed} from
    "./62440-ufarm1-9-investor-withdrawals-may-not-function-with-a-nonzer.sol";

contract Finding62440Test is Test {
    function test_exploit_withdraw_returns_before_queue() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e.pool())), 100e18, "100 stuck in the pool");
        assertEq(e.token().balanceOf(address(e)), 0, "investor received 0");
        assertEq(e.pool().queuedShares(), 0, "nothing queued");
        assertEq(e.pool().sharesOf(address(e)), 100e18, "shares still recorded");
    }

    function test_control_queues_and_pays() public {
        ValueToken token = new ValueToken();
        UFarmPoolFixed pool = new UFarmPoolFixed(token);
        token.mint(address(this), 100e18);
        token.approve(address(pool), 100e18);
        pool.deposit(100e18);
        pool.withdraw(100e18);

        assertEq(token.balanceOf(address(this)), 100e18, "investor paid 100");
        assertEq(token.balanceOf(address(pool)), 0, "pool empty");
        assertEq(pool.queuedShares(), 100e18, "queued");
        assertEq(pool.sharesOf(address(this)), 0, "shares burned");
    }
}
