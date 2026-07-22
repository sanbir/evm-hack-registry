// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38187-getactualsupply-should-be-used-instead-of-totalsupply-for-ba.sol";

contract WeakSlippageFloorTest is Test {
    /// @notice HARM: run() proves the totalSupply-based minimum lets a
    ///         sandwiched join through with less BPT than fairly owed.
    function test_exploit_weakFloorLetsSandwichedJoinThrough() public {
        Exploit e = new Exploit();
        e.run();

        uint256 received = e.pool().balanceOf(address(e.distributor()));
        assertEq(received, 204, "depositor should receive exactly 204 BPT under the sandwich");
        assertLt(received, 210, "204 BPT is strictly less than the correct 210 BPT minimum");
    }

    /// @notice Isolates the exact mechanism: totalSupply() understates
    ///         getActualSupply() by exactly the pending protocol fee, so the
    ///         computed bptAmountOut is proportionally smaller too.
    function test_buggyMinimum_isSmallerThanCorrectMinimum() public {
        MockBalancerPool pool = new MockBalancerPool(2000, 100);
        MockBalancerVault vault = new MockBalancerVault(IMockBalancerPool(address(pool)), 1000, 1000);
        pool.setVault(address(vault));
        RewardsDistributor distributor = new RewardsDistributor(vault, IMockBalancerPool(address(pool)));

        uint256 buggyMinimum = ((100 + 100) * pool.totalSupply()) / 2000;
        uint256 correctMinimum = ((100 + 100) * pool.getActualSupply()) / 2000;

        assertEq(buggyMinimum, 200, "buggy minimum uses totalSupply (2000)");
        assertEq(correctMinimum, 210, "correct minimum uses getActualSupply (2100)");
        assertLt(buggyMinimum, correctMinimum, "the buggy minimum is a weaker (smaller) slippage floor");
    }

    /// @notice Control: with the fix (getActualSupply used as the minimum),
    ///         the SAME sandwiched join reverts instead of silently executing
    ///         at a worse price -- protecting the depositor.
    function test_control_fixedMinimum_revertsTheSandwichedJoin() public {
        MockBalancerPool pool = new MockBalancerPool(2000, 100);
        MockBalancerVault vault = new MockBalancerVault(IMockBalancerPool(address(pool)), 1000, 1000);
        pool.setVault(address(vault));

        vault.frontrunSandwich();

        uint256 fixedMinimum = ((100 + 100) * pool.getActualSupply()) / 2000; // the fix: getActualSupply()
        assertEq(fixedMinimum, 210);

        vm.expectRevert(bytes("BAL#208: bptAmountOut below minimum"));
        vault.joinPool(100, 100, fixedMinimum);
    }
}
