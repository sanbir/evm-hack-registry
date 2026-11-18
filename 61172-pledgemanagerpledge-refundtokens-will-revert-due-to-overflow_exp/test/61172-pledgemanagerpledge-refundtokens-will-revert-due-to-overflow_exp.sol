// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit, PledgeManagerFixed, MiniToken} from "./61172-pledgemanagerpledge-refundtokens-will-revert-due-to-overflow.sol";
contract Finding61172Test is Test {
    function test_large_pledge_and_refund_revert() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.largeReverted());
        assertTrue(e.refundReverted());
        assertEq(e.deniedAmount(), 5_000_000_000);
        assertEq(e.userLeft(), 5_000_000_000);
    }
    function test_control_widened_multiply_pledges_5000_usdc() public {
        MiniToken stable = new MiniToken("USDC");
        PledgeManagerFixed fixedM = new PledgeManagerFixed(stable);
        stable.mint(address(this), 5_000_000_000);
        stable.approve(address(fixedM), type(uint256).max);
        uint256 got = fixedM.pledge(address(this), 1_000_000, 5000);
        assertEq(got, 5_000_000_000);
        assertEq(stable.balanceOf(address(fixedM)), 5_000_000_000);
    }
}
