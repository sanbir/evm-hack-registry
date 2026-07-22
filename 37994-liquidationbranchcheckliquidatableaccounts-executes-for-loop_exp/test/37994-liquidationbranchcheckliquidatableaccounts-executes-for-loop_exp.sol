// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {LiquidationBranch, Exploit} from "./37994-liquidationbranchcheckliquidatableaccounts-executes-for-loop.sol";

contract CheckLiquidatableAccountsTest is Test {
    /// @notice CONTROL — a segment starting at lowerBound = 0 works exactly
    ///         as intended.
    function test_lowerBoundZero_worksCorrectly() public {
        LiquidationBranch branch = new LiquidationBranch();
        for (uint256 i = 0; i < 30; i++) {
            branch.addActiveAccount(uint128(100 + i), i >= 10 && i < 20);
        }
        uint128[] memory result = branch.checkLiquidatableAccounts(0, 10);
        assertEq(result.length, 10);
    }

    /// @notice HARM — a segment with a non-zero lowerBound that contains a
    ///         liquidatable account reverts with an array out-of-bounds
    ///         Panic, exactly matching the finding's own PoC scenario
    ///         (lowerBound=10, upperBound=20) and its expected
    ///         `Panic(uint256)` selector with code 0x32.
    function test_lowerBoundNonZero_revertsOutOfBounds() public {
        LiquidationBranch branch = new LiquidationBranch();
        for (uint256 i = 0; i < 30; i++) {
            branch.addActiveAccount(uint128(100 + i), i >= 10 && i < 20);
        }

        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x32));
        branch.checkLiquidatableAccounts(10, 20);
    }

    /// @notice HARM (via Exploit) — the reduced Exploit demonstrates the
    ///         same failure using a raw staticcall (no cheatcodes), for
    ///         parity with the Playground's cheatcode-free recorder.
    function test_exploit_demonstratesOutOfBoundsRevert() public {
        Exploit exploit = new Exploit();
        exploit.run();
    }
}
