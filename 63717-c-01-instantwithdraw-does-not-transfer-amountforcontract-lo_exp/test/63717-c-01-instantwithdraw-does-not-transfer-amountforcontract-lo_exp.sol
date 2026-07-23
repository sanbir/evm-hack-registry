// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63717-c-01-instantwithdraw-does-not-transfer-amountforcontract-lo.sol";

contract BobInstantWithdrawStuckTest is Test {
    function test_penalty_stuck_in_surrogate() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stuckInSurrogate(), 0.5e18, "stuck");
        assertEq(e.contractAfter(), e.contractBefore(), "no penalty transfer");
        assertEq(e.staking().rewardTokenBalance(), 0.5e18, "paper balance");
    }
}
