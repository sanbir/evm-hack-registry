// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./55056-incorrect-calculation-of-user-shares-in-startunwinding-spear.sol";

contract Finding55056Test is Test {
    function test_bob_is_credited_alice_shares_and_alice_cannot_unwind() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.aliceReverted(), "alice reverted");
        assertEq(e.receipt().balanceOf(address(e.bob())), 2000e6, "bob");
        assertEq(e.controller().credit(address(e.bob())), 2000e6, "credit");
        assertEq(e.controller().totalReceiptTokens(), 0, "bucket");
        assertEq(e.share().balanceOf(address(e.alice())), 1000e6, "alice shares");
        assertEq(e.receipt().balanceOf(address(e.alice())), 0, "alice receipt");
    }

    function test_control_shares_argument_credits_1000() public {
        uint256 userShares = 1000e6;
        uint256 credit = (userShares * uint256(3000e6)) / uint256(3000e6);
        assertEq(credit, 1000e6, "fair");
    }
}
