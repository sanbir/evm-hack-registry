// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./34174-h-04-partially-filled-short-records-created-without-a-short.sol";

contract DittoPartialFillNoOrderTest is Test {
    function test_partiallyFilledShortRecordIsPermanentlyStuck() public {
        Exploit e = new Exploit();
        e.run();

        Vulnerable v = e.v();
        (,, Vulnerable.SR status) = v.shortRecords(address(e), 1);
        assertEq(uint256(status), uint256(Vulnerable.SR.PartialFill), "SR must remain PartialFill (never fixed)");

        // Re-assert the harm directly: exit and liquidation both permanently revert.
        vm.expectRevert(Vulnerable.InvalidShortOrder.selector);
        v.exitShort(1, 0);

        vm.expectRevert(Vulnerable.InvalidShortOrder.selector);
        v.liquidate(address(e), 1, 0);
    }

    /// @notice Control: when the leftover value clears MIN_ASK_ETH, a short order
    /// IS created and the Short Record can be exited normally — proving the bug is
    /// specifically the dust-threshold branch, not a general design choice.
    function test_control_aboveDustThreshold_exitSucceeds() public {
        Vulnerable v = new Vulnerable();
        v.placeBid(1 ether, 1 ether);
        // 3 ether short at price 1 ether: 1 ether matches the bid, 2 ether leftover
        // -> 2 ether * 1 ether / 1e18 = 2 ether notional >= MIN_ASK_ETH (1 ether).
        uint16 shortOrderId = v.createLimitShort(1, 3 ether, 1 ether);
        assertGt(shortOrderId, 0, "control: a short order should have been created");

        (,, Vulnerable.SR status) = v.shortRecords(address(this), 1);
        assertEq(uint256(status), uint256(Vulnerable.SR.PartialFill));

        // Exit succeeds because the order exists and is correctly linked.
        v.exitShort(1, shortOrderId);
        (,, Vulnerable.SR statusAfter) = v.shortRecords(address(this), 1);
        assertEq(uint256(statusAfter), uint256(Vulnerable.SR.Closed), "control: exit should succeed");
    }
}
