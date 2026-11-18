// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, EggsFixed} from "./46029-the-contract-can-be-drained-of-its-sonic-via-reentrancy-cant.sol";

contract Finding46029Test is Test {
    receive() external payable {}

    function test_reentrancy_drains_three_slices_records_one() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 1 ether);
        e.eggs().fund{value: 0.297 ether}();
        e.run();

        assertEq(address(e).balance, 0.297 ether, "exploit holds 0.297 sonic");
        assertEq(address(e.eggs()).balance, 0, "pool empty");
        assertEq(e.eggs().loans(address(e)), 0.099 ether, "recorded debt is one slice");
        assertEq(e.eggs().totalBorrowed(), 0.297 ether, "totalBorrowed counts all three");
        assertEq(e.rounds(), 2, "reentered twice");
    }

    function test_control_guard_allows_only_one_slice() public {
        EggsFixed fixedEggs = new EggsFixed();
        fixedEggs.openPosition(address(this), 0.1 ether);
        vm.deal(address(this), 1 ether);
        fixedEggs.fund{value: 0.297 ether}();
        fixedEggs.borrowMore(0.099 ether);
        assertEq(address(fixedEggs).balance, 0.198 ether, "two slices remain");
        assertEq(fixedEggs.loans(address(this)), 0.099 ether, "debt stored before the call");
        vm.expectRevert();
        fixedEggs.borrowMore(0.099 ether);
    }
}
