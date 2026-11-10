// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Distributor,
    Exploit,
    Token,
    Tracker,
    VoterFixed
} from "./62815-h-8-voterfinalize-incorrect-rewards-distribution-due-to-tran.sol";

contract Finding62815Test is Test {
    uint256 internal constant TS = 1_700_000_000;

    function test_exploit_staker_is_paid_the_whole_pot() public {
        vm.warp(TS);
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 7 days * 1 ether, "staker received the weekly pot");
        assertEq(e.left(), 0, "distributor was left with 0");
    }

    function test_control_notifies_before_the_transfer() public {
        vm.warp(TS);
        Token weth = new Token();
        Distributor distributor = new Distributor(weth);
        Tracker tracker = new Tracker(weth, distributor, address(this));
        VoterFixed voter = new VoterFixed(weth, distributor);
        distributor.setTracker(address(tracker));

        uint256 pot = 7 days * 1 ether;
        weth.mint(address(voter), pot);
        distributor.seed(1 ether, block.timestamp - 7 days);
        voter.finalize();

        assertEq(weth.balanceOf(address(this)), 0, "staker is not paid immediately");
        assertEq(weth.balanceOf(address(distributor)), pot, "WETH sits on the distributor");
    }
}
