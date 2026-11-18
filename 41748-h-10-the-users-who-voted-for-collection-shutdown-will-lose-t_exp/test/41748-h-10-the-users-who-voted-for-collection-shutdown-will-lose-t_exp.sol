// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, CollectionToken, Locker, CollectionShutdownFixed} from "./41748-h-10-the-users-who-voted-for-collection-shutdown-will-lose-t.sol";

contract VoterFixed {
    function vote(CollectionShutdownFixed s, address collection, CollectionToken token) external {
        token.approve(address(s), type(uint256).max);
        s.voteFixed(collection);
    }
}

contract Finding41748Test is Test {
    function test_exploit_cancel_keeps_both_votes() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e.voter1())), 0);
        assertEq(e.token().balanceOf(address(e.voter2())), 0);
        assertEq(e.token().balanceOf(address(e.shutdown())), 2 ether);
        assertTrue(e.shutdown().cancelled());
        assertFalse(e.shutdown().canExecute(e.collection()));
    }

    function test_control_cancel_refunds_voters() public {
        CollectionToken token = new CollectionToken();
        Locker locker = new Locker();
        CollectionShutdownFixed s = new CollectionShutdownFixed(locker);
        s.init(address(token), token);
        VoterFixed a = new VoterFixed();
        VoterFixed b = new VoterFixed();
        token.mint(address(a), 1 ether);
        token.mint(address(b), 1 ether);
        token.mint(address(0x10), 1 ether);
        a.vote(s, address(token), token);
        b.vote(s, address(token), token);
        s.cancelFixed(address(token));
        assertEq(token.balanceOf(address(a)), 1 ether, "a");
        assertEq(token.balanceOf(address(b)), 1 ether, "b");
        assertEq(token.balanceOf(address(s)), 0, "refunded");
    }
}
