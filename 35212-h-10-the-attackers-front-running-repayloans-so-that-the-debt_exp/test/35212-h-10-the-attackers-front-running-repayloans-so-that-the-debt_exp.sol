// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./35212-h-10-the-attackers-front-running-repayloans-so-that-the-debt.sol";

/*//////////////////////////////////////////////////////////////////////////
    Gondi [H-10] — mergeTranches front-runs repayLoan, seizes NFT.

    Re-asserts: repay fails after id rotation; NFT ends with lender A.
//////////////////////////////////////////////////////////////////////////*/
contract FrontrunRepayLoanTest is Test {
    function test_mergeTranches_frontrun_blocks_repay_and_seizes_nft() public {
        Exploit exp = new Exploit();
        exp.run();

        assertTrue(exp.repayWouldSucceedBefore(), "repay ok before");
        assertFalse(exp.repayWouldSucceedAfter(), "repay DoS after");
        assertEq(exp.nftOwnerAfter(), exp.LENDER_A(), "NFT to attacker/lender");
        assertEq(exp.stolenPrincipalValue(), 100e18, "face value harm");
    }
}
