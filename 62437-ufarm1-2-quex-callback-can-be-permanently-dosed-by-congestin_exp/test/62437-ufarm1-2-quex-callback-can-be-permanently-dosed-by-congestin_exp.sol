// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ValueToken, UFarmPool, UFarmPoolFixed, Investor} from
    "./62437-ufarm1-2-quex-callback-can-be-permanently-dosed-by-congestin.sol";

contract Finding62437Test is Test {
    function test_exploit_congested_callback_locks_withdrawal() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e.pool())), e.AMOUNT(), "100 stuck in the pool");
        assertEq(e.token().balanceOf(address(e.investor())), 0, "investor paid 0");
        assertEq(e.pool().sharesOf(address(e.investor())), e.AMOUNT(), "shares still recorded");
        assertEq(e.pool().depositQueueLength(), e.SPAM(), "deposit queue not drained");
        assertEq(e.pool().withdrawQueueLength(), 1, "withdrawal still queued");
        assertEq(e.pool().paidOut(), 0, "callback paid nothing");
    }

    function test_control_bounded_callback_pays_same_spam() public {
        uint256 amount = 100e18;

        ValueToken open = new ValueToken();
        UFarmPool openPool = new UFarmPool(open);
        Investor investor = new Investor();
        open.mint(address(investor), amount);
        investor.approveAndDeposit(open, openPool, amount);
        investor.queueExit(openPool, amount);
        openPool.floodDepositQueue(1);
        (bool openOk,) = address(openPool).call{gas: 1_000_000}(
            abi.encodeCall(UFarmPool.quexCallback, (uint256(1), UFarmPool.DataItem({totalCost: amount})))
        );
        assertTrue(openOk, "one empty deposit still settles");
        assertEq(open.balanceOf(address(investor)), amount, "small queue pays 100");
        assertEq(open.balanceOf(address(openPool)), 0, "small queue empties the pool");

        ValueToken token = new ValueToken();
        UFarmPoolFixed pool = new UFarmPoolFixed(token);
        token.mint(address(this), amount);
        token.approve(address(pool), amount);
        pool.depositAssets(amount);
        pool.queueWithdraw(amount);
        pool.floodDepositQueue(800);
        (bool ok,) = address(pool).call{gas: 1_000_000}(
            abi.encodeCall(UFarmPoolFixed.quexCallback, (uint256(1), UFarmPoolFixed.DataItem({totalCost: amount})))
        );
        assertTrue(ok, "cap fits in the 1m gas limit");
        assertEq(token.balanceOf(address(this)), amount, "capped callback pays 100");
        assertEq(token.balanceOf(address(pool)), 0, "capped pool is empty");
        assertEq(pool.sharesOf(address(this)), 0, "shares burned");
        assertEq(pool.paidOut(), amount, "paid 100");
    }
}
