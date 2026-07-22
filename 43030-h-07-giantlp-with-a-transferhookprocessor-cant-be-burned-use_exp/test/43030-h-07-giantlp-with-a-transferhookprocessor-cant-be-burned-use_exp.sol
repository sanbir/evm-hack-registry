// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./43030-h-07-giantlp-with-a-transferhookprocessor-cant-be-burned-use.sol";

/*//////////////////////////////////////////////////////////////
    Stakehouse Protocol — GiantLP with a transferHookProcessor can't be
    burned, users' funds stuck in the Giant Pool (H-07, #43030)

    GiantLP._beforeTokenTransfer calls transferHookProcessor.beforeTokenTransfer
    unconditionally. GiantMevAndFeesPool.beforeTokenTransfer guards the `_from`
    branch (`if (_from != address(0))`) but NOT the `_to` branch, so on a burn
    (_to == address(0)) it unconditionally calls
    _distributeETHRewardsToUserForToken(_to=0, ...) which reverts on
    `require(_recipient != address(0))`. Every withdrawETH (which burns
    GiantLP) therefore reverts forever.

    - test_exploit: drives the cheatcode-free Exploit end to end (funded via
      msg.value), then re-asserts the stuck-funds harm from the driver.
    - test_withdrawAlwaysReverts: standalone rebuild mirroring the finding's
      own PoC shape (EOA deposits then withdraws).
    - test_control_transferWorks: control — a non-burning transfer (to a real
      address, `_to != address(0)`) succeeds fine, isolating the missing `_to`
      guard as the defect.
//////////////////////////////////////////////////////////////*/
contract GiantLPBurnRevertTest is Test {
    /// @notice HARM via the self-contained Exploit: deposited ETH becomes
    ///         permanently unwithdrawable because burn always reverts.
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run{value: e.DEPOSIT_AMOUNT()}();

        GiantMevAndFeesPool pool = e.pool();
        GiantLP lp = pool.lpTokenETH();

        // Re-assert the HARM independently from the driver.
        assertEq(pool.idleETH(), e.DEPOSIT_AMOUNT(), "deposit still idle, never withdrawn");
        assertEq(lp.balanceOf(address(e)), e.DEPOSIT_AMOUNT(), "user still holds the un-burnable GiantLP");
        assertEq(address(pool).balance, e.DEPOSIT_AMOUNT(), "pool still holds the ETH, unreachable");

        uint256 depositAmount = e.DEPOSIT_AMOUNT();
        vm.prank(address(e));
        vm.expectRevert("Zero address");
        pool.withdrawETH(depositAmount);
    }

    /// @notice Standalone rebuild mirroring the finding's own PoC shape: an
    ///         EOA deposits then tries to withdraw and it reverts.
    function test_withdrawAlwaysReverts() public {
        GiantMevAndFeesPool pool = new GiantMevAndFeesPool();

        address user = makeAddr("feesAndMevUserOne");
        vm.deal(user, 4 ether);

        vm.startPrank(user);
        pool.depositETH{value: 4 ether}(4 ether);

        vm.expectRevert("Zero address");
        pool.withdrawETH(4 ether);
        vm.stopPrank();

        // Funds are stuck: still idle, GiantLP never burnt.
        assertEq(pool.idleETH(), 4 ether);
        assertEq(pool.lpTokenETH().balanceOf(user), 4 ether);
    }

    /// @notice Control: a plain (non-burning) GiantLP transfer to a REAL
    ///         address succeeds — isolating the missing `_to != address(0)`
    ///         guard in beforeTokenTransfer as the defect, not the hook
    ///         mechanism itself.
    function test_control_transferWorks() public {
        GiantMevAndFeesPool pool = new GiantMevAndFeesPool();
        GiantLP lp = pool.lpTokenETH();

        address user = makeAddr("user");
        address other = makeAddr("other");
        vm.deal(user, 1 ether);

        vm.prank(user);
        pool.depositETH{value: 1 ether}(1 ether);

        // Directly exercise the hook path with a real (non-zero) `_to`
        // by re-minting to `other` (mint uses _to = other, never address(0)).
        vm.prank(address(pool));
        lp.mint(other, 1 ether); // does not revert — `_to` is a real address

        assertEq(lp.balanceOf(other), 1 ether, "mint to a real recipient succeeds");
    }
}
