// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    DepositToken,
    Depositor,
    Exploit,
    ShareSink,
    TimeLockPoolFixed
} from "./56297-deposits-and-shares-may-get-stuck-zokyo-none-rainmaker-markd.sol";

contract Finding56297Test is Test {
    function test_exploit_transfer_sticks_deposit_and_shares() public {
        Exploit e = new Exploit();
        e.run();

        assertFalse(e.user1Withdrew(), "depositor withdraw failed");
        assertFalse(e.user2Withdrew(), "recipient withdraw failed");
        assertEq(e.stuck(), 1_000 ether, "1000 tokens stuck in pool");
        assertEq(e.user2Shares(), 1_000 ether, "shares stuck on sink");
        assertEq(e.user1Deposits(), 1, "deposit record stayed with user1");
    }

    function test_control_moving_deposits_lets_recipient_withdraw() public {
        DepositToken token = new DepositToken();
        TimeLockPoolFixed pool = new TimeLockPoolFixed(token);
        Depositor user1 = new Depositor();
        ShareSink user2 = new ShareSink();

        token.mint(address(user1), 1_000 ether);
        user1.approveAndDepositFixed(pool, token, 1_000 ether);
        user1.xferFixed(pool, address(user2), 1_000 ether);

        assertTrue(user2.tryWithdrawFixed(pool), "recipient withdraws");
        assertEq(token.balanceOf(address(user2)), 1_000 ether, "tokens out");
        assertEq(token.balanceOf(address(pool)), 0, "pool empty");
    }
}
