// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Reward,
    VoterFixed
} from "./62810-h-3-dosed-voterfinalize-due-to-unbounded-pending-removals-la.sol";

contract Finding62810Test is Test {
    function test_exploit_finalize_reverts_and_rewards_stick() public {
        Exploit e = new Exploit();
        e.run();
        assertFalse(e.finalized(), "finalize");
        assertEq(e.token().balanceOf(address(e.voter())), 100 ether, "stuck");
        assertEq(e.token().balanceOf(e.payee()), 0, "payee");
        emit log_named_uint("stuck rewards", e.token().balanceOf(address(e.voter())));
    }

    function test_control_batch_finalizes_and_pays() public {
        Reward token = new Reward();
        address payee = address(0xBEEF);
        VoterFixed voter = new VoterFixed(token, payee);
        voter.enroll(address(0xA1));
        voter.enroll(address(0xA2));
        voter.enroll(address(0xA3));
        token.mint(address(voter), 100 ether);
        voter.finalize(3);
        assertEq(voter.distributed(), 100 ether, "paid N");
        assertEq(token.balanceOf(payee), 100 ether, "payee");
        assertEq(token.balanceOf(address(voter)), 0, "voter empty");
    }
}
