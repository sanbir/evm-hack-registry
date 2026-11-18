// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Matic, BranchFixed, Alice} from "./37518-method-depositrequest-allows-the-last-deposit-to-be-more-tha.sol";

contract Finding37518Test is Test {
    function test_exploit_last_deposit_clears_the_cap() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.branch().liquidity(0), 5_990_000 ether, "5.99M kept");
        assertEq(e.branch().capAmount(0), 1_000_000 ether, "cap");
        assertEq(e.matic().balanceOf(address(e.branch())), 5_990_000 ether, "custody");
        assertTrue(e.branch().depositCapReached(0), "flag");
    }

    function test_control_over_cap_deposit_reverts() public {
        Matic matic = new Matic();
        BranchFixed branch = new BranchFixed(matic);
        branch.setCap(0, 1_000_000 ether);
        matic.mint(address(this), 5_990_000 ether);
        matic.approve(address(branch), 990_000 ether);
        branch.depositRequest(0, 990_000 ether);
        matic.approve(address(branch), 5_000_000 ether);
        vm.expectRevert();
        branch.depositRequest(0, 5_000_000 ether);
        assertEq(branch.liquidity(0), 990_000 ether, "stays under cap");
    }
}
