// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import "./interfaces/IV3SwapRouter.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IDRLFactory.sol";
import "./libraries/PriceTick.sol";
import "./libraries/LiquidityHelper.sol";

interface IWETH9 {
    function deposit() external payable;

    function withdraw(uint256 wad) external;
}

contract DRLVaultV3 is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    // Constants
    int24 constant MAX_TICK = 887272;
    int24 constant MIN_TICK = -887272;

    // Initialization flag
    bool private initialized;

    // Vault factory
    address public vaultFactory;

    // Vault owner
    address public owner;

    // NonFungiblePositionManager address
    INonfungiblePositionManager public positionManager;

    // QuoterV2 address
    IQuoterV2 public quoterV2;

    // SwapRouter
    IV3SwapRouter public swapRouter;

    // Uniswap v3 factory
    IUniswapV3Factory public uniswapV3Factory;

    // WETH address
    address public WETH;

    // NFT tokenId
    uint256 public lpTokenId;

    // Vault fee
    uint24 public fee;

    uint24 public slippageBps;

    struct UserLiquidity {
        uint256 tokenId;
        uint128 liquidity;
    }

    mapping(address => UserLiquidity) public userLiquidity;

    // token0 (sorted)
    address public token0;

    // token1 (sorted)
    address public token1;

    // Events
    event TokensDeposited(address indexed user, address token, uint256 amount);
    event TokensWithdrawn(address indexed user, address token, uint256 amount);
    event UserClaimed(address indexed user, address token, uint256 amount);
    event FeesCollected(address indexed user, address token, uint256 amount);
    event PositionMinted(address indexed user, uint256 tokenId, int24 tickLower, int24 tickUpper);
    event PositionRemoved(address indexed user, uint256 tokenId);
    event LiquidityRebalanced(
        address indexed user, uint256 oldTokenId, uint256 newTokenId, int24 newTickLower, int24 newTickUpper
    );

    // Errors
    error AddLiquidityFailed();
    error PoolDoesNotExist();
    error NoLiquidityToRebalance();

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyOperator() {
        address operator = IDRLFactory(vaultFactory).getOperator();
        require(msg.sender == operator, "Not operator");
        _;
    }

    /// @notice Initialize the vault (replaces constructor for clone pattern)
    /// @dev Can only be called once
    function initialize(
        address _tokenA,
        address _tokenB,
        uint24 _fee,
        address _weth,
        address _operator,
        address _positionManager,
        address _quoterV2,
        address _swapRouter,
        address _v3Factory,
        address _vaultFactory,
        address _owner
    ) external {
        require(!initialized, "Already initialized");
        initialized = true;

        vaultFactory = _vaultFactory;
        owner = _owner;
        fee = _fee;
        WETH = _weth;
        (token0, token1) = sortTokens(_tokenA, _tokenB);
        positionManager = INonfungiblePositionManager(_positionManager);
        quoterV2 = IQuoterV2(_quoterV2);
        swapRouter = IV3SwapRouter(_swapRouter);
        uniswapV3Factory = IUniswapV3Factory(_v3Factory);

        // Default slippage: 50 = 0.5%
        slippageBps = 50;
    }

    /// @notice Add all available liquidity to a new position
    /// @param _fee Pool fee tier
    /// @param _priceLower Lower price bound
    /// @param _priceUpper Upper price bound
    function addLiquidityALL(uint24 _fee, uint256 _priceLower, uint256 _priceUpper) external onlyOperator {
        require(userLiquidity[owner].tokenId == 0, "LP already exist!");

        // Update fee
        fee = _fee;

        // Get Pool address and verify it exists
        address poolAddress = uniswapV3Factory.getPool(token0, token1, _fee);
        if (poolAddress == address(0)) revert PoolDoesNotExist();
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        int24 currentTick;
        uint160 sqrtPriceX96;
        (sqrtPriceX96, currentTick,,,,,) = pool.slot0();

        int24 _tickSpacing = pool.tickSpacing();
        (int24 tickLower, int24 tickUpper) =
            calculatePriceToTicker(uint160(_priceLower), uint160(_priceUpper), _tickSpacing);

        // Get sqrt ratios
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        require(sqrtRatioAX96 < sqrtPriceX96 && sqrtPriceX96 < sqrtRatioBX96, "Price not in range");

        uint256 _totalUSDC = IERC20(token0).balanceOf(address(this));
        require(_totalUSDC > 0, "Not enough USDC");

        (uint256 amount0, uint256 amount1) =
            LiquidityHelper.getLiquidityAmounts(_totalUSDC, sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96);

        uint256 requiredUSDC = 0;
        uint256 requiredWETH = 0;
        if (currentTick < tickLower) {
            // Add USDC side liquidity
            requiredUSDC = _totalUSDC;
            requiredWETH = 0;
        } else if (currentTick > tickUpper) {
            // Add WETH side liquidity
            requiredUSDC = 0;
            requiredWETH = swapToWETH(_totalUSDC);
        } else {
            // Add range liquidity
            requiredUSDC = amount0;
            requiredWETH = swapToWETH(amount1);
        }

        IERC20(token0).approve(address(positionManager), requiredUSDC);
        IERC20(token1).approve(address(positionManager), requiredWETH);

        // Mint position with slippage protection
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: _fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: requiredUSDC,
            amount1Desired: requiredWETH,
            amount0Min: (requiredUSDC * (10000 - slippageBps)) / 10000,
            amount1Min: (requiredWETH * (10000 - slippageBps)) / 10000,
            recipient: address(this),
            deadline: block.timestamp + 300
        });

        (uint256 _tokenId, uint128 _liquidity,,) = positionManager.mint(params);

        lpTokenId = _tokenId;
        userLiquidity[owner].tokenId = _tokenId;
        userLiquidity[owner].liquidity = _liquidity;

        emit PositionMinted(owner, _tokenId, tickLower, tickUpper);

        // Swap remaining WETH to USDC
        swapToUsdc();
    }

    /// @notice Rebalance liquidity to a new price range
    /// @param _priceLower New lower price bound
    /// @param _priceUpper New upper price bound
    function rebase(uint256 _priceLower, uint256 _priceUpper) external onlyOperator nonReentrant {
        // 1. Check if liquidity exists
        if (userLiquidity[owner].tokenId == 0) revert NoLiquidityToRebalance();

        uint256 oldTokenId = userLiquidity[owner].tokenId;

        // 2. Remove existing liquidity
        _removeLiquidity();

        // 3. Get current token balances after removing liquidity
        uint256 currentToken0 = IERC20(token0).balanceOf(address(this));
        uint256 currentToken1 = IERC20(token1).balanceOf(address(this));
        require(currentToken0 > 0 || currentToken1 > 0, "No tokens after removal");

        // 4. Get pool info
        address poolAddress = uniswapV3Factory.getPool(token0, token1, fee);
        if (poolAddress == address(0)) revert PoolDoesNotExist();
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        int24 currentTick;
        uint160 sqrtPriceX96;
        (sqrtPriceX96, currentTick,,,,,) = pool.slot0();

        int24 _tickSpacing = pool.tickSpacing();
        (int24 tickLower, int24 tickUpper) =
            calculatePriceToTicker(uint160(_priceLower), uint160(_priceUpper), _tickSpacing);

        // Get sqrt ratios
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        require(sqrtRatioAX96 < sqrtPriceX96 && sqrtPriceX96 < sqrtRatioBX96, "Price not in range");

        // 5. Calculate total value in token0 terms
        uint256 token1ValueInToken0 = currentToken1 > 0 ? getQuoteForWETH(fee, currentToken1) : 0;
        uint256 totalValueInToken0 = currentToken0 + token1ValueInToken0;

        // 6. Calculate required token amounts for new range
        uint256 requiredToken0;
        uint256 requiredToken1;

        if (currentTick < tickLower) {
            // Below range: need 100% token0
            requiredToken0 = totalValueInToken0;
            requiredToken1 = 0;

            // Swap all token1 to token0 if needed
            if (currentToken1 > 0) {
                uint256 received = _swapExactInput(token1, token0, currentToken1);
                currentToken0 = IERC20(token0).balanceOf(address(this));
            }
        } else if (currentTick > tickUpper) {
            // Above range: need 100% token1
            requiredToken0 = 0;
            requiredToken1 = currentToken1 + (currentToken0 > 0 ? getQuoteForUSDC(fee, currentToken0) : 0);

            // Swap all token0 to token1 if needed
            if (currentToken0 > 0) {
                uint256 received = _swapExactInput(token0, token1, currentToken0);
                currentToken1 = IERC20(token1).balanceOf(address(this));
            }
        } else {
            // In range: calculate optimal ratio
            (uint256 amount0Needed, uint256 amount1ToSwap) =
                LiquidityHelper.getLiquidityAmounts(totalValueInToken0, sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96);

            requiredToken0 = amount0Needed;

            // Calculate how much token1 we need
            uint256 amount1Needed = getQuoteForUSDC(fee, amount1ToSwap);
            requiredToken1 = amount1Needed;

            // Adjust balances with single swap
            if (currentToken0 > amount0Needed) {
                // Have excess token0, need more token1
                uint256 excessToken0 = currentToken0 - amount0Needed;
                uint256 token1Deficit = amount1Needed > currentToken1 ? amount1Needed - currentToken1 : 0;

                if (token1Deficit > 0) {
                    // Calculate how much token0 to swap
                    uint256 token0ToSwap = excessToken0 < amount1ToSwap ? excessToken0 : amount1ToSwap;
                    if (token0ToSwap > 0) {
                        _swapExactInput(token0, token1, token0ToSwap);
                    }
                }
            } else if (currentToken1 > amount1Needed) {
                // Have excess token1, need more token0
                uint256 excessToken1 = currentToken1 - amount1Needed;
                uint256 token0Deficit = amount0Needed > currentToken0 ? amount0Needed - currentToken0 : 0;

                if (token0Deficit > 0 && excessToken1 > 0) {
                    // Swap excess token1 to token0
                    _swapExactInput(token1, token0, excessToken1);
                }
            }
        }

        // 7. Get final balances after swaps
        uint256 finalToken0 = IERC20(token0).balanceOf(address(this));
        uint256 finalToken1 = IERC20(token1).balanceOf(address(this));

        // 8. Add liquidity in new range
        IERC20(token0).approve(address(positionManager), finalToken0);
        IERC20(token1).approve(address(positionManager), finalToken1);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: finalToken0,
            amount1Desired: finalToken1,
            amount0Min: (finalToken0 * (10000 - slippageBps)) / 10000,
            amount1Min: (finalToken1 * (10000 - slippageBps)) / 10000,
            recipient: address(this),
            deadline: block.timestamp + 300
        });

        (uint256 _tokenId, uint128 _liquidity,,) = positionManager.mint(params);

        lpTokenId = _tokenId;
        userLiquidity[owner].tokenId = _tokenId;
        userLiquidity[owner].liquidity = _liquidity;

        emit LiquidityRebalanced(owner, oldTokenId, _tokenId, tickLower, tickUpper);

        // 9. Optionally swap remaining dust back to token0
        uint256 remainingToken1 = IERC20(token1).balanceOf(address(this));
        if (remainingToken1 > 0) {
            swapToUsdc();
        }
    }

    /// @notice Internal function to perform exact input swap
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Amount to swap
    /// @return amountOut Amount received
    function _swapExactInput(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        if (amountIn == 0) return 0;

        IERC20(tokenIn).approve(address(swapRouter), amountIn);

        // Get quote for slippage protection
        uint256 expectedOut;
        if (tokenIn == WETH) {
            expectedOut = getQuoteForWETH(fee, amountIn);
        } else {
            expectedOut = getQuoteForUSDC(fee, amountIn);
        }

        uint256 minAmountOut = (expectedOut * (10000 - slippageBps)) / 10000;

        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);
    }

    /// @notice Operator add liquidity with specific parameters
    function addLiquidity(
        address _token0,
        address _token1,
        uint256 amount0ToMint,
        uint256 amount1ToMint,
        uint24 _fee,
        int24 tickLower,
        int24 tickUpper
    ) external onlyOperator {
        require(userLiquidity[owner].tokenId == 0, "Vault liquidity already created!");

        if ((_token0 != token0 && _token1 != token1) && (_token0 != token1 && _token1 != token0)) {
            revert("Liquidity token not supported");
        }

        if (_token0 == WETH) {
            require(address(this).balance >= amount0ToMint, "Not enough WETH balance");
            require(IERC20(_token1).balanceOf(address(this)) >= amount1ToMint, "Not enough token balance");
            IWETH9(_token0).deposit{value: amount0ToMint}();
            uint256 _wethBalance = IERC20(_token0).balanceOf(address(this));
            require(
                _wethBalance >= amount0ToMint,
                string(abi.encodePacked("Token0 Not enough eth balance: ", _wethBalance.toString()))
            );
            require(IERC20(_token1).balanceOf(address(this)) >= amount1ToMint, "Not enough USDC token");
        } else {
            IWETH9(_token1).deposit{value: amount1ToMint}();
            require(IERC20(_token1).balanceOf(address(this)) >= amount1ToMint, "Token1 Not enough eth balance");
            require(IERC20(_token0).balanceOf(address(this)) >= amount0ToMint, "Not enough USDC token");
        }

        IERC20(_token0).approve(address(positionManager), amount0ToMint);
        IERC20(_token1).approve(address(positionManager), amount1ToMint);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: _fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0ToMint,
            amount1Desired: amount1ToMint,
            amount0Min: (amount0ToMint * (10000 - slippageBps)) / 10000,
            amount1Min: (amount1ToMint * (10000 - slippageBps)) / 10000,
            recipient: address(this),
            deadline: block.timestamp + 300
        });

        (uint256 _tokenId, uint128 _liquidity,,) = positionManager.mint(params);

        lpTokenId = _tokenId;
        userLiquidity[owner].tokenId = _tokenId;
        userLiquidity[owner].liquidity = _liquidity;

        emit PositionMinted(owner, _tokenId, tickLower, tickUpper);
    }

    /// @notice Operator remove all liquidity
    function removeLiquidity() external onlyOperator {
        require(userLiquidity[owner].tokenId != 0, "Vault liquidity does not exist");
        _removeLiquidity();
        swapToUsdc();
    }

    /// @notice Internal function to remove liquidity
    function _removeLiquidity() internal {
        uint128 liquidity = userLiquidity[owner].liquidity;
        uint256 tokenId = userLiquidity[owner].tokenId;

        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp + 300
            });

        positionManager.decreaseLiquidity(params);
        _collect();
        positionManager.burn(tokenId);

        emit PositionRemoved(owner, tokenId);

        // Reset liquidity
        delete userLiquidity[owner];
    }

    /// @notice Get vault balance in token0 (USDC)
    /// @return amount Balance of token0
    function getVaultBalance() external view returns (uint256 amount) {
        return IERC20(token0).balanceOf(address(this));
    }

    /// @notice Owner withdraw tokens
    function withdrawTokens(address token, uint256 amount) external onlyOwner nonReentrant {
        require(token == token1 || token == token0, "Invalid token");
        require(amount > 0, "Invalid amount");

        if (token == WETH) {
            uint256 balance = IERC20(WETH).balanceOf(address(this));
            IWETH9(WETH).withdraw(balance);
            require(address(this).balance >= amount, "Insufficient balance");
            (bool sent,) = msg.sender.call{value: amount}("");
            require(sent, "ETH transfer failed");
        } else {
            IERC20(token).transfer(msg.sender, amount);
        }

        emit TokensWithdrawn(msg.sender, token, amount);
    }

    receive() external payable {}

    fallback() external payable {}

    /// @notice Deposit tokens into vault
    function deposite(uint256 amount1) external payable onlyOwner nonReentrant {
        require(amount1 > 0 || msg.value > 0, "No tokens or ETH sent");

        if (msg.value > 0) {
            emit TokensDeposited(msg.sender, token0 == WETH ? token0 : token1, msg.value);
        }

        if (amount1 > 0) {
            if (token0 != WETH) {
                IERC20(token0).transferFrom(msg.sender, address(this), amount1);
                emit TokensDeposited(msg.sender, token0, amount1);
            } else {
                IERC20(token1).transferFrom(msg.sender, address(this), amount1);
                emit TokensDeposited(msg.sender, token1, amount1);
            }
        }
    }

    /// @notice Sort tokens to ensure token0 < token1
    function sortTokens(address tokenA, address tokenB) internal pure returns (address _token0, address _token1) {
        require(tokenA != tokenB, "Identical addresses");
        require(tokenA != address(0) && tokenB != address(0), "Zero address");

        if (tokenA < tokenB) {
            (_token0, _token1) = (tokenA, tokenB);
        } else {
            (_token0, _token1) = (tokenB, tokenA);
        }
    }

    /// @notice Collect fees from position
    /// @return amount0 Amount of token0 collected
    /// @return amount1 Amount of token1 collected
    function _collect() internal returns (uint256 amount0, uint256 amount1) {
        require(IERC721(address(positionManager)).ownerOf(lpTokenId) == address(this), "Not NFT owner");

        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: lpTokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });

        (amount0, amount1) = positionManager.collect(params);
        return (amount0, amount1);
    }

    /// @notice Owner collect fees
    function collectFees() external onlyOwner {
        _collect();
        uint256 _feesAmount = swapToUsdc();
        emit FeesCollected(msg.sender, token0, _feesAmount);
        _sendToOwner();
    }

    /// @notice Get LP token ID
    function getLPTokenId() external view onlyOwner returns (uint256) {
        require(userLiquidity[owner].tokenId > 0, "Not owned a tokenId");
        return lpTokenId;
    }

    /// @notice Send all tokens to owner
    function _sendToOwner() internal {
        uint256 usdcBalance = IERC20(token0).balanceOf(address(this));
        uint256 wethBalance = IERC20(token1).balanceOf(address(this));

        if (usdcBalance > 0) {
            TransferHelper.safeTransfer(token0, owner, usdcBalance);
        }

        if (wethBalance > 0) {
            IWETH9(WETH).withdraw(wethBalance);
            (bool sent,) = owner.call{value: wethBalance}("");
            require(sent, "ETH transfer failed");
        }
    }

    /// @notice Swap all ETH/WETH to USDC
    /// @return _amountOut Amount of USDC received
    function swapToUsdc() internal returns (uint256 _amountOut) {
        uint256 ethBalance = address(this).balance;
        uint256 wethBalance = IERC20(WETH).balanceOf(address(this));

        if (ethBalance == 0 && wethBalance == 0) return 0;

        if (ethBalance > 0) {
            IWETH9(WETH).deposit{value: ethBalance}();
        }

        wethBalance = IERC20(WETH).balanceOf(address(this));
        if (wethBalance == 0) return 0;

        uint256 expectedAmountOut = getQuoteForWETH(fee, wethBalance);

        // Fixed slippage calculation
        uint256 _amountOutMinimum = (expectedAmountOut * (10000 - slippageBps)) / 10000;

        IERC20(WETH).approve(address(swapRouter), wethBalance);
        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: token0,
            fee: fee,
            recipient: address(this),
            amountIn: wethBalance,
            amountOutMinimum: _amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        _amountOut = swapRouter.exactInputSingle(params);
    }

    /// @notice Swap USDC to WETH
    /// @param _amount Amount of USDC to swap
    /// @return _amountOut Amount of WETH received
    function swapToWETH(uint256 _amount) public returns (uint256 _amountOut) {
        if (_amount == 0) return 0;

        uint256 tokenBalance;
        address tokenIn;

        if (token0 == WETH) {
            tokenBalance = IERC20(token1).balanceOf(address(this));
            require(tokenBalance >= _amount, "Not enough balance");
            tokenIn = token1;
            IERC20(token1).approve(address(swapRouter), _amount);
        } else {
            tokenBalance = IERC20(token0).balanceOf(address(this));
            require(tokenBalance >= _amount, "Not enough balance");
            IERC20(token0).approve(address(swapRouter), _amount);
            tokenIn = token0;
        }

        uint256 expectedAmountOut = getQuoteForUSDC(fee, _amount);

        // Fixed slippage calculation
        uint256 _amountOutMinimum = (expectedAmountOut * (10000 - slippageBps)) / 10000;

        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: WETH,
            fee: fee,
            recipient: address(this),
            amountIn: _amount,
            amountOutMinimum: _amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        _amountOut = swapRouter.exactInputSingle(params);
    }

    /// @notice Swap all USDC to WETH
    function swapAllToWETH() external onlyOwner {
        uint256 tokenBalance;
        address tokenIn;

        if (token0 == WETH) {
            tokenBalance = IERC20(token1).balanceOf(address(this));
            tokenIn = token1;
            IERC20(token1).approve(address(swapRouter), tokenBalance);
        } else {
            tokenBalance = IERC20(token0).balanceOf(address(this));
            IERC20(token0).approve(address(swapRouter), tokenBalance);
            tokenIn = token0;
        }

        if (tokenBalance == 0) return;

        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: WETH,
            fee: fee,
            recipient: address(this),
            amountIn: tokenBalance,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        swapRouter.exactInputSingle(params);

        uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
        IWETH9(WETH).withdraw(wethBalance);
    }

    /// @notice User claim all vault assets
    function claim() external onlyOwner {
        // Remove liquidity if exists
        if (userLiquidity[owner].tokenId != 0) {
            _removeLiquidity();
        }

        // Swap all to USDC
        swapToUsdc();

        // Transfer all USDC to owner
        if (token0 != WETH) {
            uint256 tokenBalance = IERC20(token0).balanceOf(address(this));
            TransferHelper.safeTransfer(token0, owner, tokenBalance);
            emit UserClaimed(msg.sender, token0, tokenBalance);
        } else {
            uint256 tokenBalance = IERC20(token1).balanceOf(address(this));
            TransferHelper.safeTransfer(token1, owner, tokenBalance);
            emit UserClaimed(msg.sender, token1, tokenBalance);
        }
    }

    /// @notice Calculate price to ticker
    function calculatePriceToTicker(uint160 _lowerPrice, uint160 _upperPrice, int24 _tickSpacing)
        public
        pure
        returns (int24, int24)
    {
        require(_lowerPrice < _upperPrice, "Invalid price range");
        (int24 tickLower, int24 tickUpper) = PriceTick.getTickRangeV2(_lowerPrice, _upperPrice, _tickSpacing);
        return (tickLower, tickUpper);
    }

    /// @notice Get quote for swapping USDC to WETH
    function getQuoteForUSDC(uint24 _fee, uint256 _amountIn) public returns (uint256) {
        IQuoterV2.QuoteExactInputSingleParams memory quoteParams = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: token0, tokenOut: WETH, fee: _fee, amountIn: _amountIn, sqrtPriceLimitX96: 0
        });

        (uint256 amountOut,,,) = quoterV2.quoteExactInputSingle(quoteParams);
        return amountOut;
    }

    /// @notice Get quote for swapping WETH to USDC
    function getQuoteForWETH(uint24 _fee, uint256 _amountIn) public returns (uint256) {
        IQuoterV2.QuoteExactInputSingleParams memory quoteParams = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: WETH, tokenOut: token0, fee: _fee, amountIn: _amountIn, sqrtPriceLimitX96: 0
        });

        (uint256 amountOut,,,) = quoterV2.quoteExactInputSingle(quoteParams);
        return amountOut;
    }

    /// @notice Get current price quote
    function getQuote(uint24 _fee) public returns (uint256) {
        IQuoterV2.QuoteExactInputSingleParams memory quoteParams = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: WETH, tokenOut: token0, fee: _fee, amountIn: 1000000000000000000, sqrtPriceLimitX96: 0
        });

        (uint256 amountOut,,,) = quoterV2.quoteExactInputSingle(quoteParams);
        return amountOut;
    }

    /// @notice Get LP value in USDC
    /// @return _value Value of LP in USDC
    function getLPValue() external returns (uint256 _value) {
        require(userLiquidity[owner].tokenId > 0, "Not valid tokenId");

        (,, address _token0, address _token1, uint24 _fee, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            positionManager.positions(userLiquidity[owner].tokenId);
        require(liquidity > 0, "No liquidity in this LP");

        address poolAddress = uniswapV3Factory.getPool(token0, token1, fee);
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        uint160 sqrtLowerX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        (uint256 amount0, uint256 amount1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liquidity);

        uint8 decimals0 = 6;
        uint8 decimals1 = 18;

        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / (1 << 192);

        uint256 token1ValueInUSDC = (amount1 * priceX96 * (10 ** decimals0)) / (10 ** decimals1);

        uint256 lpValuedUSDC = amount0 + token1ValueInUSDC;

        return lpValuedUSDC;
    }

    /// @notice Get slippage BPS
    /// @return _slippageBps Slippage in basis points
    function getSlippageBps() external view returns (uint24 _slippageBps) {
        return slippageBps;
    }

    /// @notice Set slippage BPS
    /// @param _slippage Slippage in basis points (50 = 0.5%, 500 = 5%)
    function setSlippageBps(uint24 _slippage) external onlyOwner {
        require(_slippage <= 1000, "Slippage too high"); // Max 10%
        slippageBps = _slippage;
    }

    /// @notice Get operator address
    function getOperator() external view returns (address) {
        address operator = IDRLFactory(vaultFactory).getOperator();
        return operator;
    }
}
