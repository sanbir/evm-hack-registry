// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Berabot — BerabotRouter multi-hop keeps the original amountIn
    (Shieldify, January 2025, H-01).
    Hop 2 of WETH -> DOGE -> DAI still quotes with the 1 WETH input instead of
    the DOGE bought on hop 1. The pair accepts the tiny DAI out, the 1 WETH
    stays in the first pair, and the user receives dust instead of the fair quote. */

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
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

contract Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;

    constructor(address a, address b) {
        require(a != b, "same");
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function mint(address token, uint256 amount) external {
        Erc20(token).mint(address(this), amount);
    }

    function sync() external {
        reserve0 = uint112(Erc20(token0).balanceOf(address(this)));
        reserve1 = uint112(Erc20(token1).balanceOf(address(this)));
    }

    function getReserves() external view returns (uint112, uint112) {
        return (reserve0, reserve1);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        require(amount0Out > 0 || amount1Out > 0, "insufficient output");
        if (amount0Out > 0) require(Erc20(token0).transfer(to, amount0Out), "t0");
        if (amount1Out > 0) require(Erc20(token1).transfer(to, amount1Out), "t1");
        uint256 balance0 = Erc20(token0).balanceOf(address(this));
        uint256 balance1 = Erc20(token1).balanceOf(address(this));
        uint256 amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "insufficient input");
        uint256 adj0 = balance0 * 1000 - amount0In * 3;
        uint256 adj1 = balance1 * 1000 - amount1In * 3;
        require(adj0 * adj1 >= uint256(reserve0) * uint256(reserve1) * 1_000_000, "K");
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
    }
}

contract BerabotRouter {
    mapping(address => mapping(address => address)) public pairs;

    error PairDoesNotExist();

    function register(address a, address b, address pair) external {
        pairs[a][b] = pair;
        pairs[b][a] = pair;
    }

    function _calculatePairAddress(address tokenIn, address tokenOut, address) internal view returns (address pair) {
        pair = pairs[tokenIn][tokenOut];
    }

    function _getReservesAndDirection(address pair, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 reserveIn, uint256 reserveOut, bool zeroForOne)
    {
        tokenOut;
        (uint112 r0, uint112 r1) = Pair(pair).getReserves();
        if (tokenIn == Pair(pair).token0()) return (r0, r1, true);
        return (r1, r0, false);
    }

    function _calculateAmountOut(uint256 reserveIn, uint256 reserveOut, uint256 amountIn, address)
        internal
        pure
        returns (uint256)
    {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    function _executeV2Swap(uint256 amountIn, address[] calldata path, address router)
        internal
        returns (uint256 amountOut)
    {
        address _router = router;
        for (uint256 i = 0; i < path.length - 1; i++) {
            address tokenIn = path[i];
            address tokenOut = path[i + 1];

            address pair = _calculatePairAddress(tokenIn, tokenOut, _router);
            if (pair.code.length == 0) revert PairDoesNotExist();

            (uint256 reserveIn, uint256 reserveOut, bool zeroForOne) =
                _getReservesAndDirection(pair, path[i], path[i + 1]);

            // @> VULN: every hop quotes with the original amountIn, not the previous hop's amountOut
            amountOut = _calculateAmountOut(reserveIn, reserveOut, amountIn, _router);

            address to = i < path.length - 2 ? _calculatePairAddress(tokenOut, path[i + 2], _router) : address(this);

            Pair(pair).swap(zeroForOne ? 0 : amountOut, zeroForOne ? amountOut : 0, to, new bytes(0));
        }
    }

    function swapExactTokensForTokens(uint256 amountIn, address[] calldata path) external returns (uint256 amountOut) {
        address first = _calculatePairAddress(path[0], path[1], address(0));
        require(Erc20(path[0]).transferFrom(msg.sender, first, amountIn), "pull");
        amountOut = _executeV2Swap(amountIn, path, address(0));
        require(Erc20(path[path.length - 1]).transfer(msg.sender, amountOut), "push");
    }

    function quote(uint256 amountIn, address[] calldata path) external view returns (uint256 amountOut) {
        amountOut = amountIn;
        for (uint256 i = 0; i < path.length - 1; i++) {
            address pair = pairs[path[i]][path[i + 1]];
            (uint256 reserveIn, uint256 reserveOut,) = _getReservesAndDirection(pair, path[i], path[i + 1]);
            amountOut = _calculateAmountOut(reserveIn, reserveOut, amountOut, address(0));
        }
    }
}

contract FixedRouter {
    BerabotRouter public inner;

    constructor(BerabotRouter _inner) {
        inner = _inner;
    }

    function swap(uint256 amountIn, address[] calldata path) external returns (uint256 amountOut) {
        address first = inner.pairs(path[0], path[1]);
        require(Erc20(path[0]).transferFrom(msg.sender, first, amountIn), "pull");
        uint256 running = amountIn;
        for (uint256 i = 0; i < path.length - 1; i++) {
            address pair = inner.pairs(path[i], path[i + 1]);
            (uint112 r0, uint112 r1) = Pair(pair).getReserves();
            bool zeroForOne = path[i] == Pair(pair).token0();
            uint256 reserveIn = zeroForOne ? r0 : r1;
            uint256 reserveOut = zeroForOne ? r1 : r0;
            uint256 amountInWithFee = running * 997;
            amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
            address to = i < path.length - 2 ? inner.pairs(path[i + 1], path[i + 2]) : address(this);
            Pair(pair).swap(zeroForOne ? 0 : amountOut, zeroForOne ? amountOut : 0, to, new bytes(0));
            running = amountOut;
        }
        require(Erc20(path[path.length - 1]).transfer(msg.sender, amountOut), "push");
    }
}

contract Exploit {
    Erc20 public weth; // nonce 1
    Erc20 public doge; // nonce 2
    Erc20 public dai; // nonce 3
    Pair public pair1; // nonce 4
    Pair public pair2; // nonce 5
    BerabotRouter public router; // nonce 6

    uint256 public fairDai;
    uint256 public gotDai;

    constructor() {
        weth = new Erc20("WETH");
        doge = new Erc20("DOGE");
        dai = new Erc20("DAI");
        pair1 = new Pair(address(weth), address(doge));
        pair2 = new Pair(address(doge), address(dai));
        router = new BerabotRouter();
        router.register(address(weth), address(doge), address(pair1));
        router.register(address(doge), address(dai), address(pair2));

        pair1.mint(address(weth), 100 ether);
        pair1.mint(address(doge), 200_000 ether);
        pair1.sync();
        pair2.mint(address(doge), 200_000 ether);
        pair2.mint(address(dai), 200_000 ether);
        pair2.sync();
        weth.mint(address(this), 1 ether);
    }

    function run() external {
        address[] memory path = new address[](3);
        path[0] = address(weth);
        path[1] = address(doge);
        path[2] = address(dai);
        fairDai = router.quote(1 ether, path);
        weth.approve(address(router), 1 ether);
        gotDai = router.swapExactTokensForTokens(1 ether, path);
        require(fairDai > 1_000 ether, "fair quote");
        require(gotDai > 0 && gotDai * 1_000 < fairDai, "dust out");
        require(weth.balanceOf(address(this)) == 0, "weth spent");
        require(weth.balanceOf(address(pair1)) == 101 ether, "pair kept 1 WETH");
        require(dai.balanceOf(address(this)) == gotDai, "user dust");
    }
}
