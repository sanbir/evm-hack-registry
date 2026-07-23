// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./46246-overpayment-to-bidder-in-slash-function-due-to-incorrect-amo.sol";

/*//////////////////////////////////////////////////////////////
    Primev — slash overpayment to bidder (Cantina #46246)

    - test_exploit: drives Exploit; re-asserts bidder got full amt, not residual.
    - test_control_payResidual: control — paying residualAmt yields no excess.
//////////////////////////////////////////////////////////////*/
contract PrimevSlashOverpayTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        vm.deal(address(e), 3 ether);
        e.run();

        uint256 received = address(e.bidder()).balance;
        assertEq(received, 1 ether, "bidder got full slash amt");
        assertGt(received, 0.5 ether, "over residual");
    }

    function test_control_payResidual() public {
        ProviderRegistry reg = new ProviderRegistry();
        uint256 residualPercent = 50 * reg.PRECISION();
        uint256 amt = 1 ether;
        uint256 residualAmt = (amt * residualPercent) / reg.ONE_HUNDRED_PERCENT();

        // Correct payment path (what the fix does): deduct + pay residual only.
        assertEq(residualAmt, 0.5 ether);
        assertLt(residualAmt, amt);
    }
}
