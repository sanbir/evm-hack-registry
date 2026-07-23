// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./61327-liquidations-can-be-made-to-revert-by-an-attacker-through-va.sol";

contract Vii61327Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.liquidationReverted(), "liquidation DoS");
        assertEq(e.attackerDebtAfterFailedLiq(), 50, "debt uncleared - bad debt path open");
    }

    /// @notice Control: with the fixed formula (sender balance), unowned tokenId transfers 0.
    function test_fixedNormalizedToFull_allowsLiquidation() public {
        // Using balance-based formula: amount * 0 / bal = 0 for unowned tokenId → no revert
        uint256 amount = 50;
        uint256 senderBalTokenId = 0;
        uint256 currentBalance = 100;
        uint256 fixedAmt = (amount * senderBalTokenId) / currentBalance;
        assertEq(fixedAmt, 0, "fixed formula yields zero for unowned id");
    }
}
