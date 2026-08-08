// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Taiko — [H-02] Validity and contest bonds can be incorrectly burned for the
    correct and ultimately verified transition (Code4rena 2024-03-taiko,
    reporter monrel, finding #31930).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: LibProving.proveBlock() overwrites a block's TransitionState
    record with the newest prover, discarding any claim the PREVIOUS prover's
    (already-deposited) validityBond had — with no bookkeeping that would let
    a later re-proof of the SAME transition refund the original prover. When
    LibVerifying.verifyBlock() finally pays out the bond, it only ever pays
    whoever is CURRENTLY recorded as `ts.prover` — never the prover whose
    transition is the one that is actually being verified, if that record was
    overwritten in between. So even when a Guardian later re-establishes that
    Bob's original transition T1 was in fact the correct one for parent P1,
    Bob's validity bond is never returned: it stays locked in the contract and
    the LAST prover of record (the Guardian) is the one who is refunded.

    Two lines are copied verbatim from the report (marked `@> VULN`):
      * LibProving.sol L387-392 — the unconditional transition-state overwrite.
      * LibVerifying.sol L178-189 — verify() paying `ts.prover` unconditionally.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal TKO-like ERC20 mock. No allowance bookkeeping — this contract
///      is not the vulnerable part, only a balance ledger for the bond flows.
contract MockTko {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Taiko L1 rollup bond/prove/verify system. Keyed by
///         `parentHash` (the real system keys by blockId+transition hash;
///         reduced here to the minimum needed to reproduce the bond bug: one
///         TransitionState slot per parent block, overwritten by whoever
///         proves it most recently).
contract TaikoL1 {
    struct TransitionState {
        uint96 validityBond;
        uint96 contestBond;
        address contester;
        address prover;
        uint16 tier;
    }

    MockTko public tko;
    uint96 public constant LIVENESS_BOND = 1 ether;

    mapping(bytes32 => TransitionState) public transitions; // parentHash => state

    constructor(MockTko _tko) {
        tko = _tko;
    }

    /// @notice Prove (or re-prove/override) the transition for `parentHash`.
    ///         Verbatim reduction of LibProving.sol's transition-overwrite path
    ///         (`_overrideWithHigherProof` / the initial-proof branch collapse
    ///         to the same three-line overwrite quoted in the report).
    function proveBlock(bytes32 parentHash, uint16 tier, uint96 tierValidityBond) external {
        TransitionState storage _ts = transitions[parentHash];

        // New prover posts their tier's validity bond.
        tko.transferFrom(msg.sender, address(this), tierValidityBond);

        // @> VULN (LibProving.sol L387-392): the transition record is
        // overwritten UNCONDITIONALLY with the new prover/tier/bond. Whatever
        // validityBond amount the PREVIOUS prover posted is simply dropped
        // from `_ts` here — it stays locked in this contract's balance with
        // no mapping back to the previous prover, even though their proof
        // might be the one that is ultimately verified correct later.
        _ts.validityBond = tierValidityBond;
        _ts.contestBond = 1;
        _ts.contester = address(0);
        _ts.prover = msg.sender;
        _ts.tier = tier;
        // FIX: before overwriting, if the transition hash is unchanged (i.e. a
        // guardian is merely re-confirming the SAME transition rather than
        // proving a genuinely different one), refund the previous prover's
        // validityBond to the previous prover instead of discarding the claim.
    }

    /// @notice Verify (finalize) the transition currently on record for
    ///         `parentHash`, paying out its bond. Verbatim reduction of
    ///         LibVerifying.sol L178-189.
    function verifyBlock(bytes32 parentHash) external {
        TransitionState storage ts = transitions[parentHash];

        // @> VULN (LibVerifying.sol L178-189): the bond is refunded to
        // whichever address is CURRENTLY recorded as `ts.prover` — never to
        // the prover whose transition is the one actually being verified if
        // that record was overwritten by a later (re-)prove call.
        uint256 bondToReturn = uint256(ts.validityBond) + LIVENESS_BOND;
        tko.transfer(ts.prover, bondToReturn);
    }
}

/// @dev Minimal actor contract so provers are distinct on-chain identities
///      without any cheatcodes (no `vm.prank`).
contract Actor {
    function proveBlock(TaikoL1 l1, bytes32 parentHash, uint16 tier, uint96 bond) external {
        l1.proveBlock(parentHash, tier, bond);
    }
}

contract Exploit {
    MockTko public tko;
    TaikoL1 public l1;
    Actor public bob; // honest prover of the correct transition T1
    Actor public guardian; // steps in later, re-confirms T1 is correct

    bytes32 public constant PARENT = keccak256("parent-block-P1");
    uint16 public constant TIER_SGX = 100;
    uint16 public constant TIER_GUARDIAN = 1000;
    uint96 public constant BOB_BOND = 1000 ether; // Bob's SGX-tier validity bond
    uint96 public constant GUARDIAN_BOND = 0; // guardians post no validity bond

    constructor() {
        tko = new MockTko();
        l1 = new TaikoL1(tko);
        bob = new Actor();
        guardian = new Actor();
        tko.mint(address(bob), BOB_BOND);
        // The liveness bond is escrowed separately at block-proposal time in
        // the real system (out of scope for this reduction); pre-fund it here
        // so verifyBlock() can pay it out.
        tko.mint(address(l1), l1.LIVENESS_BOND());
    }

    function run() external {
        uint256 bobBefore = tko.balanceOf(address(bob));
        require(bobBefore == BOB_BOND, "bob funded");

        // Step 1: Bob proves the correct transition T1 for parent P1,
        // posting his 1000 TKO validity bond.
        bob.proveBlock(l1, PARENT, TIER_SGX, BOB_BOND);
        (uint96 vb1, , , address prover1, ) = l1.transitions(PARENT);
        require(prover1 == address(bob) && vb1 == BOB_BOND, "bob recorded as prover");
        require(tko.balanceOf(address(bob)) == 0, "bob's bond left his balance");

        // Step 2: a Guardian later steps in and re-proves the SAME parent's
        // transition (confirming T1 is in fact the correct one — mirrors the
        // report's example where the guardian ultimately re-establishes the
        // correct transition after a contest/override in between).
        guardian.proveBlock(l1, PARENT, TIER_GUARDIAN, GUARDIAN_BOND);
        (uint96 vb2, , , address prover2, ) = l1.transitions(PARENT);
        require(prover2 == address(guardian), "guardian's re-prove overwrote bob's record");
        require(vb2 == GUARDIAN_BOND, "bob's 1000 TKO bond amount was dropped from the record");

        // Step 3: the block is verified. The transition that is *actually*
        // correct and gets verified is T1 — the one Bob originally proved —
        // but verifyBlock only ever knows the CURRENT record.
        l1.verifyBlock(PARENT);

        // HARM: Bob's validity bond (1000 TKO) is never refunded to him, even
        // though his original T1 proof is the transition that ends up
        // verified. Because the on-record validityBond was overwritten to the
        // guardian's (0), verifyBlock() only pays out the liveness bond to the
        // guardian — Bob's 1000 TKO stays PERMANENTLY LOCKED inside the
        // TaikoL1 contract with no path for anyone (Bob included) to recover it.
        require(tko.balanceOf(address(bob)) == 0, "harm: bob permanently lost his validity bond");
        require(tko.balanceOf(address(guardian)) == l1.LIVENESS_BOND(), "guardian only receives the liveness bond");
        require(
            tko.balanceOf(address(l1)) == uint256(BOB_BOND),
            "harm: bob's 1000 TKO validity bond is frozen inside the contract, unclaimable by anyone"
        );
    }
}
