// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Vertex — ammEquilibrium uses toInt on the quote (OtterSec, #48376)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the quote leg is returned with toInt (divide by 1e18) instead
    of fromInt (multiply by 1e18). For reserves of 1e36 and price 1e18 the
    quote is 1 instead of 1e36, off by 1e36. The pool pays that quote and
    keeps 1e36 - 1. The control uses fromInt and pays 1e36. */

library PRBMath {
    function toInt(int256 x) internal pure returns (int256) {
        return x / 1e18;
    }

    function fromInt(int256 x) internal pure returns (int256) {
        return x * 1e18;
    }
}

library MathHelper {
    using PRBMath for int256;

    function sqrt(int256 y) internal pure returns (int256) {
        require(y >= 0, "sqrt");
        if (y == 0) return 0;
        uint256 x = uint256(y);
        uint256 z = (x + 1) / 2;
        uint256 r = x;
        while (z < r) {
            r = z;
            z = (x / z + z) / 2;
        }
        return int256(r);
    }

    // contracts/libraries/MathHelper.sol — ammEquilibrium
    function ammEquilibrium(int256 baseX18, int256 quoteX18, int256 priceX18) internal pure returns (int256, int256) {
        if (baseX18 == 0 && quoteX18 == 0) {
            return (0, 0);
        }
        int256 k = baseX18.toInt() * quoteX18.toInt();
        // base * price * base == k
        // base = sqrt(k / price);
        int256 base = (MathHelper.sqrt(k) * 1e9) / MathHelper.sqrt(priceX18);
        // TODO: this can cause a divide by zero
        int256 quote = k / base;
        // @> VULN: quote.toInt divides by 1e18; the quote should be quote.fromInt
        return (base.fromInt(), quote.toInt());
        // FIX: return (base.fromInt(), quote.fromInt());
    }

    function ammEquilibriumFixed(int256 baseX18, int256 quoteX18, int256 priceX18)
        internal
        pure
        returns (int256, int256)
    {
        if (baseX18 == 0 && quoteX18 == 0) {
            return (0, 0);
        }
        int256 k = baseX18.toInt() * quoteX18.toInt();
        int256 base = (MathHelper.sqrt(k) * 1e9) / MathHelper.sqrt(priceX18);
        int256 quote = k / base;
        return (base.fromInt(), quote.fromInt());
    }
}

contract QuoteToken {
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

contract Trader {}

contract EquilibriumPool {
    using PRBMath for int256;

    QuoteToken public token;
    address public trader;
    int256 public baseOut;
    int256 public quoteOut;
    uint256 public paid;

    int256 public constant BASE_X18 = 1e36;
    int256 public constant QUOTE_X18 = 1e36;
    int256 public constant PRICE_X18 = 1e18;

    constructor(QuoteToken _token, address _trader) {
        token = _token;
        trader = _trader;
    }

    function swap() external {
        (int256 baseAmt, int256 quoteAmt) = MathHelper.ammEquilibrium(BASE_X18, QUOTE_X18, PRICE_X18);
        baseOut = baseAmt;
        quoteOut = quoteAmt;
        uint256 amount = uint256(quoteAmt);
        paid = amount;
        token.transfer(trader, amount);
    }
}

contract EquilibriumPoolFixed {
    QuoteToken public token;
    address public trader;
    int256 public baseOut;
    int256 public quoteOut;
    uint256 public paid;

    int256 public constant BASE_X18 = 1e36;
    int256 public constant QUOTE_X18 = 1e36;
    int256 public constant PRICE_X18 = 1e18;

    constructor(QuoteToken _token, address _trader) {
        token = _token;
        trader = _trader;
    }

    function swap() external {
        (int256 baseAmt, int256 quoteAmt) = MathHelper.ammEquilibriumFixed(BASE_X18, QUOTE_X18, PRICE_X18);
        baseOut = baseAmt;
        quoteOut = quoteAmt;
        uint256 amount = uint256(quoteAmt);
        paid = amount;
        token.transfer(trader, amount);
    }
}

contract Exploit {
    QuoteToken public token; // nonce 1
    Trader public trader; // nonce 2
    EquilibriumPool public pool; // nonce 3

    uint256 public paid;
    uint256 public fair;
    uint256 public retained;
    uint256 public constant FACTOR = 1e36;

    constructor() {
        token = new QuoteToken();
        trader = new Trader();
        pool = new EquilibriumPool(token, address(trader));
    }

    function run() external {
        fair = FACTOR;
        token.mint(address(pool), fair);
        require(token.balanceOf(address(pool)) == fair, "pool funded");
        pool.swap();
        paid = pool.paid();
        retained = token.balanceOf(address(pool));
        require(pool.baseOut() == int256(FACTOR), "base fromInt");
        require(pool.quoteOut() == 1, "quote toInt");
        require(paid == 1, "paid 1");
        require(fair / paid == FACTOR, "off by 1e36");
        require(token.balanceOf(address(trader)) == 1, "trader got 1");
        require(retained == fair - 1, "pool keeps the rest");
    }
}
