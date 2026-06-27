// SPDX-License-Identifier: MIT

pragma solidity >= 0.8.4;

import './interfaces/IWETH.sol';
import "@openzeppelin/contracts/access/Ownable.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './interfaces/ISwapFactory.sol';
import './interfaces/ISwapPair.sol';
import './libs/SafeMath.sol';
import './libs/TransferHelper.sol';

contract SwapRouter is Ownable {
    using SafeMath for uint256;

    uint256 private constant RATE_PERCISION = 10000;
    address public immutable factory;
    address public immutable WETH;
    address public stakingFactory;


    mapping(address => address) public baseTokenOf;
    mapping(address => mapping(address => bool)) public isWhiteList;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'SwapRouter: EXPIRED');
        _;
    }

    modifier checkSwapPath(address[] calldata path){
        require(path.length == 2, "path length err");
        address pair = pairFor(path[0], path[1]);
        address baseToken = baseTokenOf[pair];
        require(baseToken != address(0), "pair of path not found");
        require(isWhiteList[pair][msg.sender], "sell disabled");
        _;
    }

    event NewPairCreated(address caller, address pair, uint blockTime);
    event SellLpFeeAdded(address caller, address pair, uint addedLpBaseTokenAmount, uint blockTime);
    event WhiteListChanged(address pair, address user, bool status);

    struct CreatePairParams {
        address tokenA;
        address tokenB;
        address baseToken;
        uint amountA;
        uint amountB;
    }

    constructor(address _factory, address _WETH) Ownable(msg.sender) {
        factory = _factory;
        WETH = _WETH;
    }

    receive() external payable {
    }

    function pairFor(address tokenA, address tokenB) public view returns (address pair) {
        pair = ISwapFactory(factory).pairFor(tokenA, tokenB);
    }

    function createPair(CreatePairParams calldata paras) external {
        require(paras.baseToken == paras.tokenA || paras.baseToken == paras.tokenB, "invalid base token");
        require(ISwapFactory(factory).getPair(paras.tokenA, paras.tokenB) == address(0), "pair existed");
        require(paras.amountA > 0 && paras.amountB > 0, "invalid amountA or amountB");

        address pair = ISwapFactory(factory).createPair(paras.tokenA, paras.tokenB);
        TransferHelper.safeTransferFrom(paras.tokenA, msg.sender, pair, paras.amountA);
        TransferHelper.safeTransferFrom(paras.tokenB, msg.sender, pair, paras.amountB);
        ISwapPair(pair).mint(msg.sender);

        baseTokenOf[pair] = paras.baseToken;

        isWhiteList[pair][msg.sender] = true;

        emit NewPairCreated(msg.sender, pair, block.timestamp);
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal view returns (uint amountA, uint amountB) {
        require(ISwapFactory(factory).getPair(tokenA, tokenB) != address(0), "pair not exists");
        
        (uint reserveA, uint reserveB) = ISwapFactory(factory).getReserves(tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = ISwapFactory(factory).quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, 'SwapRouter: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = ISwapFactory(factory).quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'SwapRouter: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    // anyone can add liquidity, but LP tokens to staking contract 
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        require(to != address(0), "invalid recipient");
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = pairFor(tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = ISwapPair(pair).mint(stakingFactory);
    }

    // anyone can add liquidity, but LP tokens to staking contract 
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        require(to != address(0), "invalid recipient");
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        address pair = pairFor(token, WETH);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWETH(WETH).deposit{value : amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        liquidity = ISwapPair(pair).mint(stakingFactory);
        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = pairFor(tokenA, tokenB);
        require(pair != address(0), "pair not exists");

        ISwapPair(pair).transferFrom(msg.sender, pair, liquidity);
        (uint amount0, uint amount1) = ISwapPair(pair).burn(to);
        (address token0,) = ISwapFactory(factory).sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, 'SwapRouter: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'SwapRouter: INSUFFICIENT_B_AMOUNT');
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public  ensure(deadline) returns (uint amountETH) {
        (, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = ISwapFactory(factory).sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            address to = i < path.length - 2 ? pairFor(output, path[i + 2]) : _to;
            ISwapPair(pairFor(input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal returns(uint) {
        (address input, address output) = (path[0], path[1]);
        (address token0,) = ISwapFactory(factory).sortTokens(input, output);
        ISwapPair pair = ISwapPair(pairFor(input, output));
        uint amountInput;
        uint amountOutput;
        {// scope to avoid stack too deep errors
            (uint reserve0, uint reserve1,) = pair.getReserves();
            (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
            amountOutput = ISwapFactory(factory).getAmountOut(amountInput, reserveInput, reserveOutput, input, output);
        }

        (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
        pair.swap(amount0Out, amount1Out, _to, new bytes(0));

        return amountInput;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external ensure(deadline) checkSwapPath(path) {
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, pairFor(path[0], path[1]), amountIn
        );
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'SwapRouter: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable ensure(deadline) checkSwapPath(path) {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        uint amountIn = msg.value;
        IWETH(WETH).deposit{value: amountIn}();
        assert(IWETH(WETH).transfer(pairFor(path[0], path[1]), amountIn));
        uint balanceBefore = IERC20(path[1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'SwapRouter: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external ensure(deadline) checkSwapPath(path) {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, pairFor(path[0], path[1]), amountIn
        );
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint amountOut = IERC20(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin, 'SwapRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }


    function setWhiteList(address pair, address account, bool status) external {
        require(msg.sender == stakingFactory || msg.sender == owner(), "caller must be creator");
        isWhiteList[pair][account] = status;
        
        emit WhiteListChanged(pair,account,status);
    }

    function setStakingFactory(address _stakingFactory) external onlyOwner {
	require(_stakingFactory != address(0), "invalid address");
        stakingFactory = _stakingFactory;
    }

    function takeToken(address pair, address token, uint amount) external {
        require(msg.sender == stakingFactory, "only staking contract is authorized");
        ISwapPair(pair).takeToken(token, amount);
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public view returns (uint256 amountB) {
        return ISwapFactory(factory).quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, address token0, address token1) public view returns (uint256 amountOut){
        return ISwapFactory(factory).getAmountOut(amountIn, reserveIn, reserveOut, token0, token1);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, address token0, address token1) public view returns (uint256 amountIn){
        return ISwapFactory(factory).getAmountIn(amountOut, reserveIn, reserveOut, token0, token1);
    }

    function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts){
        return ISwapFactory(factory).getAmountsOut(amountIn, path);
    }

    function getAmountsIn(uint256 amountOut, address[] memory path) public view returns (uint256[] memory amounts){
        return ISwapFactory(factory).getAmountsIn(amountOut, path);
    }
}
