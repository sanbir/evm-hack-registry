// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./34118-h-01-game-fee-locked-in-earlyendgame-pashov-audit-group-none.sol";

contract FindingTest is Test {
    function test_attack() public {
        Exploit e = new Exploit();
        e.run{value: 1 ether}();

        assertEq(e.stuck(), 0.1 ether);
        assertEq(e.treasuryBal(), 0);
        assertEq(e.game().feeTaken(), 0.1 ether);
        assertEq(e.game().paidToPlayer(), 0.9 ether);
        assertEq(e.player().balance, 0.9 ether);
    }

    function test_control() public {
        Exploit e = new Exploit();
        e.runControl{value: 1 ether}();
    }
}
