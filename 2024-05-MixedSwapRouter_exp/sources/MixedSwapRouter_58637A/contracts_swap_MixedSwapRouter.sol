// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "./interfaces/IUniswap.sol";

import "../lib/SafeCast.sol";
import "../lib/Path.sol";
import "../lib/TickMath.sol";
import "../lib/UniswapV2Library.sol";
import "../base/PeripheryPayments.sol";
import "./interfaces/IAlgebraSwapCallback.sol";

pragma solidity ^0.8.12;

contract MixedSwapRouter is OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PeripheryPayments {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using Path for bytes;
    using SafeCast for uint256;
    using BytesLib for bytes;

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMin;
        address[] pool;
    }

    struct SwapCallbackData {
        bytes path;
        address payer;
        address pool;
    }

    mapping(address => bool) public v3Pools;
    mapping(address => bool) public whitelist;
    address public feeManager;
    uint256 public fee;

    //Gap
    uint256[46] private __gap;

    function _authorizeUpgrade(address) internal override onlyOwner {
        
    }

    function initialize(address _WETH9) public override reinitializer(8)  {
        __Ownable_init();
        super.initialize(_WETH9);
    }

    /*
    @dev: Let owner rescue stuck ERC20 token.
    */
    function rescueERC20(address token, address recipient, uint256 amount) external onlyOwner {
        IERC20Upgradeable(token).safeTransfer(recipient, amount);
    }

    function swapETHForTokens(ExactInputParams memory params) external payable nonReentrant {
        require(msg.value > 0, "InvalidETHValue");
        require(params.path.slice(0, 20).toAddress() == WETH9, "NotWETH");
        params.amountIn = msg.value;
        _swap(params, false);
    }

    function swapTokensForTokens(ExactInputParams memory params) external nonReentrant {
        _swap(params, false);
    }

    function swapTokensForETH(ExactInputParams memory params) external nonReentrant {
        uint256 pathLength = params.path.length;
        require(pathLength > 20, "InvalidPath");
        require(params.path.slice(params.path.length - 20, 20).toAddress() == WETH9, "NotWETH");
        _swap(params, true);
    }

    function _swap(ExactInputParams memory params, bool wrapped) internal returns (uint256 amountOut) {
        if (AddressUpgradeable.isContract(msg.sender)) {
            require(whitelist[msg.sender], "FBD");
        }

        require(params.deadline > block.timestamp, "Expired");
        require(params.pool.length > 0 && params.pool.length == params.path.numPools(), "Invalid pool");
        require((params.amountIn + msg.value) > 0 && params.amountOutMin > 0, "Invalid amount");

        uint256 poolLength = params.pool.length;
        uint256 wethBalanceBefore = wrapped ? IWETH9(WETH9).balanceOf(address(this)) : 0;
        address payer = msg.sender;
        address recipient = address(this);

        for (uint256 i = 0; i < poolLength; i++) {
            //Check last loop and correct recipient if require wrapped
            if (i == poolLength - 1 && !wrapped) {
                recipient = params.recipient;
            }

            //Swap
            if (isV3(params.pool[i])) {
                params.amountIn = _exactInputInternalV3(
                    params.amountIn,
                    recipient,
                    SwapCallbackData({
                        path: params.path.getFirstPool(),
                        payer: payer,
                        pool: params.pool[i]
                    })
                );
            } else {
                params.amountIn = _swapV2(
                    params,
                    i,
                    recipient
                );
            }

            amountOut = params.amountIn;
            params.path = params.path.skipToken();
            payer = address(this);
        }

        require(amountOut >= params.amountOutMin, "Too little received");

        if (wrapped) {
            uint256 wethBalanceAfter = IWETH9(WETH9).balanceOf(address(this));
            uint256 diff = wethBalanceAfter - wethBalanceBefore;
            require(amountOut >= diff, "InvalidAmountOut");
            IWETH9(WETH9).withdraw(amountOut);
            (bool success, ) = params.recipient.call{value: amountOut}("");
            require(success, "WrappedFail");
        }
    }

    function _exactInputInternalV3(
        uint256 amountIn,
        address recipient,
        SwapCallbackData memory data
    ) internal returns (uint256 amountOut) {
        //Allow swapping to the router address with address 0
        if (recipient == address(0)) recipient = address(this);

        (address tokenA, address tokenB, ) = data.path.decodeFirstPool();
        _validatePoolTokens(
            tokenA,
            tokenB,
            data.pool
        );
        bool zeroForOne = tokenA < tokenB;

        (int256 amount0, int256 amount1) = IUniswap(data.pool).swap(
            recipient,
            zeroForOne,
            amountIn.toInt256(),
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            abi.encode(data)
        );

        return uint256(-(zeroForOne ? amount1 : amount0));
    }

    //Uniswap v3 callback
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) public {
        _processV3Callback(amount0Delta, amount1Delta, _data);
    }

    //AlgebraSwap v3 callback
    function algebraSwapCallback(
        int256 amount0,
        int256 amount1,
        bytes calldata data
    ) public {
        _processV3Callback(amount0, amount1, data);
    }

    function _processV3Callback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) internal {
        require(_reentrancyGuardEntered(), "FBD");
        require(amount0Delta > 0 || amount1Delta > 0, "Invalid amount"); // swaps entirely within 0-liquidity regions are not supported
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        require(msg.sender == data.pool, "Invalid caller");
        (address tokenIn, address tokenOut, ) = data.path.decodeFirstPool();
        _validatePoolTokens(
            tokenIn,
            tokenOut,
            data.pool
        );

        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0
                ? (tokenIn < tokenOut, uint256(amount0Delta))
                : (tokenOut < tokenIn, uint256(amount1Delta));
        if (isExactInput) {
            pay(tokenIn, data.payer, msg.sender, amountToPay);
        } else {
            // either initiate the next swap or pay
            if (data.path.hasMultiplePools()) {
                data.path = data.path.skipToken();
                _exactOutputInternalV3(
                    amountToPay,
                    msg.sender,
                    0,
                    data
                );
            } else {
                tokenIn = tokenOut; // swap in/out because exact output swaps are reversed
                pay(tokenIn, data.payer, msg.sender, amountToPay);
            }
        }
    }

    function isV3(address pool) public view returns (bool) {
        if (v3Pools[pool]) {
            return true;
        }
        
        try IUniswapChecker(pool).fee() returns (uint24) {
            return true;
        } catch (bytes memory) {
            return false;
        }
    }

    function getTokens(address pool) public view returns (address, address) {
        address token0 = IUniswapChecker(pool).token0();
        address token1 = IUniswapChecker(pool).token1();
        return (token0, token1);
    }

    function _getFirstPool(
        address[] memory pools
    ) internal pure returns (address) {
        return pools[0];
    }

    function _swapV2(
        ExactInputParams memory params,
        uint256 i,
        address to
    ) internal returns (uint256 amountOut) {
        (address tokenA, address tokenB, ) = params.path.decodeFirstPool();
        address[] memory pool = new address[](1);
        pool[0] = params.pool[i];
        (address token0, ) = _validatePoolTokens(tokenA, tokenB, pool[0]);

        address[] memory v2Path = new address[](2);
        v2Path[0] = tokenA;
        v2Path[1] = tokenB;
        uint256[] memory amounts = UniswapV2Library.getAmountsOut(params.amountIn, v2Path, pool);
           
        //Pay token to first pool if first pool is v2 pool
        pay(tokenA, i == 0 ? msg.sender : address(this), pool[0], amounts[0]);

        amountOut = amounts[amounts.length - 1];
        (uint256 amount0Out, uint256 amount1Out) = tokenA == token0 
            ? (uint(0), amountOut) : (amountOut, uint(0));

        IUniswap(pool[0]).swap(
            amount0Out,
            amount1Out,
            to,
            new bytes(0)
        );
    }

    function _validatePoolTokens(
        address tokenA,
        address tokenB,
        address pool
    ) internal view returns (address token0, address token1) {
        (token0, token1) = getTokens(pool);
        require((token0 == tokenA && token1 == tokenB) || (token0 == tokenB && token1 == tokenA), "InvalidPoolToken");
    }

    function unwrapWETH9(uint256 amountMinimum, address recipient) public payable override onlyOwner {
        super.unwrapWETH9(amountMinimum, recipient);
    }

    function sweepToken(
        address token,
        uint256 amountMinimum,
        address recipient
    ) public payable override onlyOwner {
        super.sweepToken(token, amountMinimum, recipient);
    }

    function refundETH() public payable override onlyOwner {
        super.refundETH();
    }

    function setV3Pool(address _pool, bool _isV3) external onlyOwner {
        v3Pools[_pool] = _isV3;
    }

    /// @dev Performs a single exact output swap
    function _exactOutputInternalV3(
        uint256 amountOut,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountIn) {
        require(data.pool != address(0), "InvalidPool");
        // allow swapping to the router address with address 0
        if (recipient == address(0)) recipient = address(this);

        (address tokenA, address tokenB, ) = data.path.decodeFirstPool();
        _validatePoolTokens(
            tokenA,
            tokenB,
            data.pool
        );
        bool zeroForOne = tokenA < tokenB;

        (int256 amount0Delta, int256 amount1Delta) = IUniswap(data.pool).swap(
                recipient,
                zeroForOne,
                -amountOut.toInt256(),
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96,
                abi.encode(data)
            );

        uint256 amountOutReceived;
        (amountIn, amountOutReceived) = zeroForOne
            ? (uint256(amount0Delta), uint256(-amount1Delta))
            : (uint256(amount1Delta), uint256(-amount0Delta));
        // it's technically possible to not receive the full output amount,
        // so if no price limit has been specified, require this possibility away
        if (sqrtPriceLimitX96 == 0) require(amountOutReceived == amountOut);
    }

    function setWhitelist(address account, bool isWhitelist) external onlyOwner {
        whitelist[account] = isWhitelist;
    }

    function setFeeManager(address _feeManager) external onlyOwner {
        feeManager = _feeManager;
    }

    function setFee(uint256 _fee) external onlyOwner {
        require(_fee < 1000, "Excd");
        fee = _fee;
    }
}