// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, CreditBondsFixed} from "./48699-dos-by-draining-creditsbonds-using-clearunusedbond-ottersec.sol";

contract Finding48699Test is Test {
    function test_exploit_clear_drains_200_and_blocks_b() public {
        Exploit e = new Exploit();
        vm.deal(address(e.payerA()), 200 ether);
        vm.deal(address(e.payerB()), 300 ether);
        e.run();
        assertEq(e.drained(), 200 ether, "drained 200");
        assertEq(e.leftInBonds(), 100 ether, "100 left");
        assertEq(e.bobSpent(), false, "B cannot spend");
        assertEq(address(e).balance, 200 ether, "attacker received 200");
    }

    function test_control_used_credit_is_not_cleared_again() public {
        CreditBondsFixed bonds = new CreditBondsFixed(address(new Sink()));
        address a = address(0xA11CE);
        address b = address(0xB0B);
        vm.deal(a, 200 ether);
        vm.deal(b, 300 ether);
        vm.prank(a);
        bonds.bond{value: 200 ether}();
        bonds.rollEpoch();
        vm.prank(a);
        bonds.sendToVault(a, 200 ether);
        vm.prank(b);
        bonds.bond{value: 300 ether}();
        bonds.rollEpoch();
        uint256 before = address(this).balance;
        bonds.clearUnusedBond(1);
        assertEq(address(this).balance, before, "nothing left to clear");
        vm.prank(b);
        bonds.sendToVault(b, 300 ether);
        assertEq(bonds.userCredit(2, b), 0, "B spent 300");
    }

    receive() external payable {}
}

contract Sink {
    receive() external payable {}
}
