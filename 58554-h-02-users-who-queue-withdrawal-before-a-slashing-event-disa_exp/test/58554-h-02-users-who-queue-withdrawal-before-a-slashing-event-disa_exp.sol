// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Hype,
    KHYPE,
    LateUser,
    StakingManagerFixed
} from "./58554-h-02-users-who-queue-withdrawal-before-a-slashing-event-disa.sol";

contract Finding58554Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_preslash_queue_takes_the_whole_reserve() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.earlyPaid(), 75 ether, "early withdrawal pays the stored 75");
        assertEq(e.lateOwed(), 21_428_571_428_571_428_571, "late quote after the slash");
        assertFalse(e.lateConfirmed(), "late confirm reverts");
        assertEq(e.hype().balanceOf(address(e.manager())), 0, "nothing left");
        assertEq(e.hype().balanceOf(ATTACKER), 75 ether, "attacker received 75 HYPE");
    }

    function test_control_recomputes_the_rate_and_pays_both() public {
        Hype hype = new Hype();
        KHYPE kHype = new KHYPE();
        StakingManagerFixed manager = new StakingManagerFixed(hype, kHype);
        LateUser late = new LateUser();

        kHype.mint(address(this), 50 ether);
        kHype.mint(address(late), 20 ether);
        hype.mint(address(manager), 105 ether);
        kHype.approve(address(manager), type(uint256).max);
        late.approve(kHype, address(manager));
        manager.seed(105 ether, 70 ether);

        manager.queueWithdrawal(50 ether);
        manager.slash(30 ether);
        late.queueFixed(manager, 20 ether);

        uint256 earlyPaid = manager.confirmWithdrawal(0);
        uint256 latePaid = late.confirmFixed(manager, 0);

        assertEq(earlyPaid, 53_571_428_571_428_571_428, "early is paid the post-slash share");
        assertEq(latePaid, 21_428_571_428_571_428_572, "late is paid the rest");
        assertEq(earlyPaid + latePaid, 75 ether, "the 75 HYPE reserve is split");
        assertTrue(latePaid > 0, "late is not left at zero");
        assertTrue(earlyPaid < 75 ether, "early does not take the whole reserve");
    }
}
