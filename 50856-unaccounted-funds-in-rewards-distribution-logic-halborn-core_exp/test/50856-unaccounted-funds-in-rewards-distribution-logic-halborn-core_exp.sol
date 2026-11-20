// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Rejector, RewardsFixed} from "./50856-unaccounted-funds-in-rewards-distribution-logic-halborn-core.sol";

contract Foundation {
    receive() external payable {}
}

contract Finding50856Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_failed_send_leaves_100_unaccounted() public {
        vm.deal(address(this), 100 ether);
        Exploit e = new Exploit();
        e.run{value: 100 ether}();
        assertEq(e.rewards().remain(), 0, "remain spent");
        assertEq(address(e.rewards()).balance, 100 ether, "100 stuck");
        assertEq(e.marker().balanceOf(SINK), 100 ether, "marked");
    }

    function test_control_failed_send_forwards_the_remainder() public {
        vm.deal(address(this), 100 ether);
        Rejector rejector = new Rejector();
        Foundation foundation = new Foundation();
        RewardsFixed rewards = new RewardsFixed(address(rejector), address(foundation));
        rewards.receiveRewards{value: 100 ether}();
        assertEq(address(rewards).balance, 0, "nothing stuck");
        assertEq(address(foundation).balance, 100 ether, "foundation receives 100");
    }
}
