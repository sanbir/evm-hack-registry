pragma solidity =0.6.6;

import "./libraries/UniswapV2Library.sol";
import "./libraries/SafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IERC20.sol";

contract UniswapV2Router {
    using SafeMath for uint;

    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BASE = 10000;

    address public immutable factory;

    bool public initialized;
    address public token;
    address public recipient;
    address public pool;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        _;
    }

    constructor(address _factory, address _token, address _recipient) public {
        factory = _factory;
        token = _token;
        recipient = _recipient;
    }

    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal virtual returns (uint amountA, uint amountB) {
        // create the pair if it doesn't exist yet
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB, address(this));
        }
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "UniswapV2Router: INSUFFICIENT_B_AMOUNT");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, "UniswapV2Router: INSUFFICIENT_A_AMOUNT");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external virtual ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        // add liquidity once
        require(initialized == false, "UniswapV2Router: INITIALIZED");
        initialized = true;

        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = UniswapV2Library.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(
                amount0Out,
                amount1Out,
                to,
                new bytes(0)
            );
        }
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual ensure(deadline) returns (uint[] memory amounts) {
        require(path.length == 2 && path[0] == token, "UniswapV2Router: INVALID_PATH");

        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, address(this));

        address pair = UniswapV2Library.pairFor(factory, path[0], path[1]);
        TransferHelper.safeTransfer(path[1], to, (amounts[1] * 9700) / BASE);
        TransferHelper.safeTransfer(path[1], pair, (amounts[1] * 300) / BASE);
        if (IERC20(token).totalSupply() - IERC20(token).balanceOf(BURN) > 100000000 * 1e4) {
            IUniswapV2Pair(pair).claim(token, BURN, (amounts[0] * 19500) / BASE);
            IUniswapV2Pair(pair).claim(token, recipient, (amounts[0] * 500) / BASE);
        }
        IUniswapV2Pair(pair).sync();
    }

    function sync(address pair) external {
        require(msg.sender == pool, "UniswapV2: FORBIDDEN");
        IUniswapV2Pair(pair).sync();
    }

    function setToken(address _token) external {
        require(msg.sender == IUniswapV2Factory(factory).feeToSetter(), "UniswapV2: FORBIDDEN");
        token = _token;
    }

    function setRecipient(address _recipient) external {
        require(msg.sender == IUniswapV2Factory(factory).feeToSetter(), "UniswapV2: FORBIDDEN");
        recipient = _recipient;
    }

    function setPool(address _pool) external {
        require(msg.sender == IUniswapV2Factory(factory).feeToSetter(), "UniswapV2: FORBIDDEN");
        pool = _pool;
    }
}
