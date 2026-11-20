// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, EvenSplitGroupPoolFixed} from
    "./52385-malicious-ip-owner-can-drain-rewards-via-duplicate-entries-i.sol";

contract Finding52385Test is Test {
    address internal constant ALICE = 0x1111111111111111111111111111111111111111;

    function test_exploit_duplicate_ip_takes_15() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(ALICE), 15 ether, "one ip took 15");
        assertEq(e.token().balanceOf(address(e.pool())), 0, "pool empty");
        assertEq(e.pool().totalPaid(), 15 ether, "paid 15");
    }

    function test_control_duplicate_ip_is_paid_once() public {
        Token token = new Token();
        EvenSplitGroupPoolFixed pool = new EvenSplitGroupPoolFixed(token);
        address[] memory ids = new address[](3);
        ids[0] = ALICE;
        ids[1] = ALICE;
        ids[2] = ALICE;
        uint256 paid = pool.distributeRewards(ids);
        assertEq(paid, 5 ether, "one share");
        assertEq(token.balanceOf(ALICE), 5 ether, "alice received 5");
        assertEq(token.balanceOf(address(pool)), 10 ether, "the other 10 stays");
    }
}
