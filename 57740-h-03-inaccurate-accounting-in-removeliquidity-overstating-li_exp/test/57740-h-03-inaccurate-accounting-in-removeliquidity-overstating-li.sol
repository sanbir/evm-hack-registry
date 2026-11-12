// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Hyperhyper LiquidityFacet.removeLiquidity — poolAmount drops by the
    net amount while the fee also leaves the pool
    (Pashov Audit Group, H-03, 30 March 2025, finding 57740).
    SYNTHETIC, cheatcode-free. One transaction, no warp.

    outAmount = 500 ether, pFee = 50 ether, netOut = 450 ether.
    Both the net and the fee are transferred out, but poolAmount is
    reduced only by netOut. Accounting is left at 550 ether against
    500 ether of tokens. The remaining LP is owed 550 ether and is
    short 50 ether. The fixed path subtracts outAmount, and that
    shortfall is 0. */

contract Asset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LiquidityFacet {
    Asset public token;
    address public feeTo;
    uint256 public poolAmount;
    uint256 public protocolFee;
    uint256 public totalLp;
    mapping(address => uint256) public lpOf;
    bool public chargeFull;

    constructor(Asset token_, address feeTo_, bool chargeFull_) {
        token = token_;
        feeTo = feeTo_;
        chargeFull = chargeFull_;
    }

    function seed(address a, address b, uint256 each) external {
        poolAmount = each * 2;
        totalLp = each * 2;
        lpOf[a] = each;
        lpOf[b] = each;
        token.mint(address(this), each * 2);
    }

    function _removeLiquidityFromPool(address user, uint256 lpAmount) internal returns (uint256 netOut, uint256 pFee) {
        uint256 outAmount = poolAmount * lpAmount / totalLp;
        pFee = outAmount / 10;
        netOut = outAmount - pFee;
        protocolFee += pFee;
        // @> VULN: poolAmount loses only netOut. The tokens that leave are netOut + pFee.
        poolAmount -= chargeFull ? outAmount : netOut;
        totalLp -= lpAmount;
        lpOf[user] -= lpAmount;
        require(token.transfer(user, netOut), "net");
        require(token.transfer(feeTo, pFee), "fee");
    }

    function removeLiquidity(uint256 lpAmount) external returns (uint256 netOut, uint256 pFee) {
        return _removeLiquidityFromPool(msg.sender, lpAmount);
    }

    function owed(address user) public view returns (uint256) {
        if (totalLp == 0) return 0;
        return poolAmount * lpOf[user] / totalLp;
    }

    function shortfall(address user) public view returns (uint256) {
        uint256 due = owed(user);
        uint256 bal = token.balanceOf(address(this));
        return due > bal ? due - bal : 0;
    }
}

contract Lp {
    function pull(LiquidityFacet pool, uint256 lpAmount) external returns (uint256 netOut, uint256 pFee) {
        return pool.removeLiquidity(lpAmount);
    }
}

contract Exploit {
    address public constant FEE_TO = address(0xFEEE);
    uint256 public constant EACH = 500 ether;
    uint256 public constant FEE = 50 ether;

    Asset public token; // nonce 1
    Lp public lp1; // nonce 2
    Lp public lp2; // nonce 3
    LiquidityFacet public pool; // nonce 4

    uint256 public accounted;
    uint256 public tokensLeft;
    uint256 public gap;
    bool public secondReverted;

    constructor() {
        token = new Asset();
        lp1 = new Lp();
        lp2 = new Lp();
        pool = new LiquidityFacet(token, FEE_TO, false);
        pool.seed(address(lp1), address(lp2), EACH);
    }

    function run() external {
        lp1.pull(pool, EACH);
        accounted = pool.poolAmount();
        tokensLeft = token.balanceOf(address(pool));
        require(accounted == 550 ether, "poolAmount is 550");
        require(tokensLeft == 500 ether, "only 500 tokens remain");
        gap = pool.shortfall(address(lp2));
        require(gap == FEE, "later LP is short 50");
        (bool ok,) = address(lp2).call(abi.encodeWithSelector(lp2.pull.selector, pool, EACH));
        secondReverted = !ok;
        require(secondReverted, "the later withdraw reverts");
        require(pool.shortfall(address(lp2)) == FEE, "shortfall stays 50");
        require(token.balanceOf(FEE_TO) == FEE, "fee receiver holds the 50");
    }
}
