// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {BatchSharesFixed, Bold, Exploit} from "./53947-h-01-bold-batch-shares-math-can-be-rebased-by-combining-roun.sol";

contract Finding53947Test is Test {
    function test_exploit_zero_shares_and_99_assets() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.sharesMinted(), 0, "zero shares");
        assertEq(e.assetsMinted(), 99, "99 assets");
        assertEq(e.owed(), 0, "owes nothing");
        assertEq(e.rebasedDebt(), 199, "existing share rebased 100 to 199");
        assertEq(e.bold().balanceOf(address(this)), 99, "caller received 99");
    }

    function test_control_rounds_shares_up_and_does_not_rebase() public {
        Bold bold = new Bold();
        BatchSharesFixed batch = new BatchSharesFixed(address(bold));
        uint256 before = batch.recordedDebt(address(0xBEEF));
        uint256 sharesDelta = batch.increaseDebt(99);
        uint256 owed = batch.recordedDebt(address(this));

        assertEq(before, 100, "starting debt");
        assertEq(sharesDelta, 1, "one share minted");
        assertEq(bold.balanceOf(address(this)), 99, "99 bold minted");
        assertEq(owed, 99, "caller owes the 99");
        assertEq(batch.recordedDebt(address(0xBEEF)), 99, "existing share was not rebased upward");
        assertEq(batch.totalDebtShares(), 2, "shares increased");
    }
}
