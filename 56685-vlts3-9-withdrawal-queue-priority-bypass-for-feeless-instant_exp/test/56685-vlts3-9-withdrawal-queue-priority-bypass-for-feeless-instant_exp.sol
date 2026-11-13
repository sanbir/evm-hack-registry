// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, QueueFixed} from "./56685-vlts3-9-withdrawal-queue-priority-bypass-for-feeless-instant.sol";

contract Finding56685Test is Test {
    address internal constant FIRST = 0x3333333333333333333333333333333333333333;
    address internal constant LATER = 0x2222222222222222222222222222222222222222;

    function test_exploit_later_request_takes_fill() public {
        Exploit e = new Exploit();
        vm.deal(address(e), 10 ether);
        e.run();

        assertEq(e.firstCheckpoint(), 0, "first cursor");
        assertEq(e.laterCheckpoint(), 0, "later cursor");
        assertEq(e.received(), 10 ether, "fill");
        assertEq(e.paidToLater(), 1 ether, "later took 1");
        assertEq(LATER.balance, 1 ether, "later balance");
        assertTrue(e.firstReady(), "first is time-ready");
        assertFalse(e.user1Claimed(), "first cannot take 10");
        assertEq(address(e).balance, 9 ether, "9 stuck behind the short queue");
        assertEq(FIRST.balance, 0, "first received nothing");
    }

    function test_control_queue_pays_first() public {
        QueueFixed q = new QueueFixed();
        vm.deal(address(q), 10 ether);
        q.open(FIRST, 10 ether);
        q.open(LATER, 1 ether);
        q.update();

        bool laterClaimed;
        try q.claim(1) {
            laterClaimed = true;
        } catch {}
        assertFalse(laterClaimed, "later request must wait");

        q.claim(0);
        assertEq(q.paidToFirst(), 10 ether, "control pays the first LP 10");
        assertEq(FIRST.balance, 10 ether, "first received 10");
        assertEq(LATER.balance, 0, "later still waiting");
        assertEq(address(q).balance, 0, "fill consumed by the first LP");
    }
}
