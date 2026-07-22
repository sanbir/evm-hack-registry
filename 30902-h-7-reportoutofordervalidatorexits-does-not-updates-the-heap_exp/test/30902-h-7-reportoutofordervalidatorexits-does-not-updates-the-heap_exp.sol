// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30902-h-7-reportoutofordervalidatorexits-does-not-updates-the-heap.sol";

contract HeapNotReorderedTest is Test {
    using OperatorUtilizationHeap for OperatorUtilizationHeap.Data;

    Exploit internal exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    function test_exploit() public {
        exploit.run();

        OperatorRegistry registry = exploit.registry();

        // Re-assert the harm from outside run(): operator 1 still has all 5
        // active deposits untouched, even though the withdrawal needed only 3.
        (,, uint40 op1Exited) = registry.validatorDetails(1);
        assertEq(op1Exited, 0, "operator 1 should be completely untouched");

        (,, uint40 op2Exited) = registry.validatorDetails(2);
        assertEq(op2Exited, 15, "operator 2 should already be fully exited");

        // The stale heap still reports operator 2 (0% utilization) as max.
        OperatorUtilizationHeap.Data memory heap = registry.getOperatorUtilizationHeapForETH();
        assertEq(heap.getMax().id, 2, "heap should still (incorrectly) report operator 2 as max");
    }

    /// @notice Control: WITHOUT any out-of-order exit report, the heap
    ///         correctly identifies operator 2 as most-utilized and
    ///         deallocateETHDeposits() correctly draws from it.
    function test_control_normalDeallocationWorksWithoutOutOfOrderExit() public {
        OperatorRegistry registry = new OperatorRegistry();
        registry.addOperator(1, 100, 5);
        registry.addOperator(2, 100, 15);
        registry.initializeHeap();

        // No reportOutOfOrderValidatorExits call — the heap accurately
        // reflects reality the whole time.
        uint256 deallocated = registry.deallocateETHDeposits(3);
        assertEq(deallocated, 3, "deallocation should fully succeed when the heap is accurate");

        (,, uint40 op2Exited) = registry.validatorDetails(2);
        assertEq(op2Exited, 3, "the correctly-identified max-utilization operator should absorb the deallocation");
    }
}
