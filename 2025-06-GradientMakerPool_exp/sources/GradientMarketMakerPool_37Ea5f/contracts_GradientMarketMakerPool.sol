// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IGradientRegistry.sol";
import "./interfaces/IGradientMarketMakerPool.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IUniswapV2Factory.sol";

contract GradientMarketMakerPool is
    Ownable,
    ReentrancyGuard,
    IGradientMarketMakerPool
{
    using SafeERC20 for IERC20;

    IGradientRegistry public gradientRegistry;

    mapping(address => PoolInfo) public pools; // token => PoolInfo
    mapping(address => mapping(address => MarketMaker)) public marketMakers; // token => user => info

    uint256 public constant SCALE = 1e18;

    // Events
    event LiquidityDeposited(
        address indexed user,
        address token,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 lpSharesMinted
    );
    event LiquidityWithdrawn(
        address indexed user,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 lpSharesBurned
    );
    event RewardDeposited(address indexed from, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);

    event PoolBalanceUpdated(
        address indexed token,
        uint256 newTotalEth,
        uint256 newTotalToken,
        uint256 newTotalLiquidity,
        uint256 newTotalLPShares
    );

    modifier poolExists(address token) {
        address pairAddress = getPairAddress(token);
        require(pairAddress != address(0), "Pair does not exist");
        require(pools[token].uniswapPair != address(0), "Pool not initialized");
        _;
    }

    modifier isNotBlocked(address token) {
        require(!gradientRegistry.blockedTokens(token), "Token is blocked");
        _;
    }

    modifier onlyRewardDistributor() {
        require(
            gradientRegistry.isRewardDistributor(msg.sender),
            "Only reward distributor can call this function"
        );
        _;
    }

    modifier onlyOrderbook() {
        require(
            msg.sender == gradientRegistry.orderbook(),
            "Only orderbook can call this function"
        );
        _;
    }

    constructor(IGradientRegistry _gradientRegistry) Ownable(msg.sender) {
        gradientRegistry = _gradientRegistry;
    }

    /**
     * @notice Updates pool rewards before modifying state
     * @param token Address of the token for the pool
     * @param ethAmount Amount of ETH to distribute as rewards
     */
    function _updatePool(address token, uint256 ethAmount) internal {
        PoolInfo storage pool = pools[token];

        if (pool.totalLPShares == 0) return;

        pool.accRewardPerShare += (ethAmount * SCALE) / pool.totalLPShares;
        pool.rewardBalance += ethAmount;
    }

    /**
     * @notice Allows users to provide liquidity to a pool
     * @param token Address of the token to provide liquidity for
     * @param tokenAmount Amount of tokens to deposit
     * @param minTokenAmount Minimum amount of tokens to accept (slippage protection)
     * @dev Requires ETH to be sent with the transaction in the correct ratio
     * @dev Calculates pending rewards before updating user's liquidity
     */
    function provideLiquidity(
        address token,
        uint256 tokenAmount,
        uint256 minTokenAmount
    ) external payable nonReentrant {
        PoolInfo storage pool = pools[token];

        if (pool.uniswapPair == address(0)) {
            pool.uniswapPair = getPairAddress(token);
        }
        require(pool.uniswapPair != address(0), "Pair does not exist");

        // Get reserves from Uniswap pair
        (uint256 reserveETH, uint256 reserveToken) = getReserves(token);
        require(
            reserveETH > 0 && reserveToken > 0,
            "Insufficient liquidity in Uniswap pair"
        );

        uint256 expectedTokens = (msg.value * reserveToken) / reserveETH;

        // Slippage protection - ensure user gets at least minTokenAmount
        require(tokenAmount >= minTokenAmount, "Slippage too high");

        // Allow 1% slippage tolerance for the ratio check
        require(
            tokenAmount >= (expectedTokens * 99) / 100 &&
                tokenAmount <= (expectedTokens * 101) / 100,
            "Invalid liquidity ratio"
        );

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        MarketMaker storage mm = marketMakers[token][msg.sender];
        uint256 userLiquidity = mm.tokenAmount + mm.ethAmount;

        // Calculate pending reward before update
        if (userLiquidity > 0) {
            uint256 pending = (userLiquidity * pool.accRewardPerShare) /
                SCALE -
                mm.rewardDebt;
            mm.pendingReward += pending;
        }

        // Calculate LP shares to mint
        uint256 lpSharesToMint;
        if (pool.totalLPShares == 0) {
            // First liquidity provider gets shares equal to their contribution
            lpSharesToMint = tokenAmount + msg.value;
        } else {
            // Calculate shares based on proportional contribution
            uint256 totalContribution = tokenAmount + msg.value;
            lpSharesToMint =
                (totalContribution * pool.totalLPShares) /
                pool.totalLiquidity;
        }

        mm.ethAmount += msg.value;
        mm.tokenAmount += tokenAmount;
        mm.lpShares += lpSharesToMint;

        mm.rewardDebt =
            ((mm.tokenAmount + mm.ethAmount) * pool.accRewardPerShare) /
            SCALE;

        pool.totalLiquidity += tokenAmount + msg.value;
        pool.totalEth += msg.value;
        pool.totalToken += tokenAmount;
        pool.totalLPShares += lpSharesToMint;

        emit LiquidityDeposited(
            msg.sender,
            token,
            msg.value,
            tokenAmount,
            lpSharesToMint
        );
    }

    /// @notice Allows market maker to withdraw liquidity and claim pending rewards
    /// @param token Address of the token to withdraw from
    /// @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
    function withdrawLiquidity(
        address token,
        uint256 shares
    ) external nonReentrant {
        PoolInfo storage pool = pools[token];
        MarketMaker storage mm = marketMakers[token][msg.sender];

        require(shares > 0 && shares <= 10000, "Invalid shares percentage");
        require(pool.totalLiquidity > 0, "No liquidity in pool");

        uint256 userLiquidity = mm.tokenAmount + mm.ethAmount;
        require(userLiquidity > 0, "No liquidity to withdraw");

        // Calculate pending rewards before withdrawing
        uint256 pending = (userLiquidity * pool.accRewardPerShare) /
            SCALE -
            mm.rewardDebt;
        mm.pendingReward += pending;

        // Calculate LP shares to burn based on withdrawal percentage
        uint256 lpSharesToBurn = (mm.lpShares * shares) / 10000;
        require(lpSharesToBurn > 0, "No shares to burn");

        // Calculate actual withdrawal amounts based on LP shares
        uint256 actualTokenWithdraw = (pool.totalToken * lpSharesToBurn) /
            pool.totalLPShares;
        uint256 actualEthWithdraw = (pool.totalEth * lpSharesToBurn) /
            pool.totalLPShares;

        // Update user's recorded balances proportionally
        uint256 userTokenReduction = (mm.tokenAmount * shares) / 10000;
        uint256 userEthReduction = (mm.ethAmount * shares) / 10000;

        // Update balances
        mm.tokenAmount -= userTokenReduction;
        mm.ethAmount -= userEthReduction;
        mm.lpShares -= lpSharesToBurn;

        pool.totalLiquidity -= actualTokenWithdraw + actualEthWithdraw;
        pool.totalToken -= actualTokenWithdraw;
        pool.totalEth -= actualEthWithdraw;
        pool.totalLPShares -= lpSharesToBurn;

        // Check if this is a 100% withdrawal
        bool isFullWithdrawal = (shares == 10000);

        // If full withdrawal, send accumulated fees and reset values
        if (isFullWithdrawal) {
            uint256 totalRewards = mm.pendingReward;
            if (totalRewards > 0) {
                mm.pendingReward = 0;
                mm.rewardDebt = 0;

                // Send accumulated fees to user
                (bool successFee, ) = payable(msg.sender).call{
                    value: totalRewards
                }("");
                require(successFee, "Fee transfer failed");

                emit RewardClaimed(msg.sender, totalRewards);
            }
        } else {
            // For partial withdrawals, update reward debt normally
            mm.rewardDebt =
                ((mm.tokenAmount + mm.ethAmount) * pool.accRewardPerShare) /
                SCALE;
        }

        // Transfer tokens and ETH back to user
        IERC20(token).safeTransfer(msg.sender, actualTokenWithdraw);
        (bool success, ) = payable(msg.sender).call{value: actualEthWithdraw}(
            ""
        );
        require(success, "ETH transfer failed");

        emit LiquidityWithdrawn(
            msg.sender,
            actualTokenWithdraw,
            actualEthWithdraw,
            lpSharesToBurn
        );
    }

    /// @notice Receives fee distribution from orderbook to be distributed to market makers
    /// @param token Address of the token pool to distribute fees for
    function receiveFeeDistribution(
        address token
    ) external payable poolExists(token) onlyRewardDistributor {
        PoolInfo storage pool = pools[token];
        require(pool.totalLiquidity > 0, "No liquidity");
        require(msg.value > 0, "No ETH sent");

        _updatePool(token, msg.value); // pass reward directly
        emit RewardDeposited(token, msg.value);
    }

    /// @notice Claims pending rewards for caller
    /// @param token Address of the token pool to claim rewards from
    function claimReward(address token) external nonReentrant {
        PoolInfo storage pool = pools[token];
        MarketMaker storage mm = marketMakers[token][msg.sender];
        require(mm.lpShares > 0, "No liquidity");

        uint256 accumulated = (mm.lpShares * pool.accRewardPerShare) / SCALE;
        uint256 reward = accumulated - mm.rewardDebt + mm.pendingReward;
        require(reward > 0, "No rewards");

        mm.rewardDebt = accumulated;
        mm.pendingReward = 0;

        (bool success, ) = payable(msg.sender).call{value: reward}("");
        require(success, "ETH transfer failed");

        emit RewardClaimed(msg.sender, reward);
    }

    /**
     * @notice Emergency withdraw function for owner to withdraw all ETH and tokens
     * @param tokens Array of token addresses to withdraw
     * @dev Only callable by contract owner
     * @dev Use this function ONLY in emergency situations such as:
     *      - Contract vulnerability or exploit detected
     *      - Critical bug in liquidity management logic
     *      - Migration to new contract version
     *      - Recovery of stuck or locked funds
     *      - Security incident requiring immediate asset protection
     * @dev This function bypasses all normal withdrawal logic and directly transfers assets
     */
    function emergencyWithdraw(address[] calldata tokens) external onlyOwner {
        // Withdraw all ETH
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (bool success, ) = owner().call{value: ethBalance}("");
            require(success, "ETH withdrawal failed");
        }

        // Withdraw all specified tokens
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (token != address(0)) {
                uint256 tokenBalance = IERC20(token).balanceOf(address(this));
                if (tokenBalance > 0) {
                    IERC20(token).safeTransfer(owner(), tokenBalance);
                }
            }
        }
    }

    /**
     * @notice Emergency withdraw function for owner to withdraw all ETH
     * @dev Only callable by contract owner
     * @dev Use this function ONLY in emergency situations such as:
     *      - Contract vulnerability or exploit detected
     *      - Critical bug in liquidity management logic
     *      - Migration to new contract version
     *      - Recovery of stuck or locked funds
     *      - Security incident requiring immediate asset protection
     * @dev This function bypasses all normal withdrawal logic and directly transfers ETH
     */
    function emergencyWithdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = owner().call{value: balance}("");
            require(success, "ETH withdrawal failed");
        }
    }

    /**
     * @notice Gets pool information for a specific token
     * @param token Address of the token to get pool info for
     * @return PoolInfo struct containing pool details
     */
    function getPoolInfo(
        address token
    ) external view returns (PoolInfo memory) {
        return pools[token];
    }

    /**
     * @notice Gets a user's current share percentage of the pool
     * @param token Address of the token
     * @param user Address of the user
     * @return sharePercentage User's share percentage in basis points (10000 = 100%)
     */
    function getUserSharePercentage(
        address token,
        address user
    ) external view returns (uint256 sharePercentage) {
        PoolInfo storage pool = pools[token];
        MarketMaker storage mm = marketMakers[token][user];

        if (pool.totalLPShares == 0) {
            return 0;
        }

        return (mm.lpShares * 10000) / pool.totalLPShares;
    }

    /**
     * @notice Gets a user's LP shares for a specific token
     * @param token Address of the token
     * @param user Address of the user
     * @return lpShares User's LP shares
     */
    function getUserLPShares(
        address token,
        address user
    ) external view returns (uint256 lpShares) {
        return marketMakers[token][user].lpShares;
    }

    /**
     * @notice Sets the gradient registry address
     * @param _gradientRegistry New gradient registry address
     * @dev Only callable by the contract owner
     */
    function setRegistry(
        IGradientRegistry _gradientRegistry
    ) external onlyOwner {
        require(
            _gradientRegistry.marketMakerPool() != address(0),
            "Invalid gradient registry"
        );
        gradientRegistry = _gradientRegistry;
    }

    /**
     * @notice Receive ETH for reward distribution
     */
    receive() external payable {}

    /**
     * @notice Transfer ETH to orderbook for order fulfillment
     * @param token The token being traded
     * @param amount The amount of ETH to transfer
     * @dev Only callable by the orderbook contract
     */
    function transferETHToOrderbook(
        address token,
        uint256 amount
    ) external isNotBlocked(token) poolExists(token) onlyOrderbook {
        require(amount > 0, "Amount must be greater than 0");
        require(amount <= address(this).balance, "Insufficient ETH balance");

        // Update pool information
        PoolInfo storage pool = pools[token];
        require(pool.totalLiquidity > 0, "No liquidity");

        // Update pool balances
        pool.totalEth -= amount;
        pool.totalLiquidity -= amount;

        // Transfer ETH to orderbook
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer to orderbook failed");

        emit PoolBalanceUpdated(
            token,
            pool.totalEth,
            pool.totalToken,
            pool.totalLiquidity,
            pool.totalLPShares
        );
    }

    /**
     * @notice Transfer tokens to orderbook for order fulfillment
     * @param token The token to transfer
     * @param amount The amount of tokens to transfer
     * @dev Only callable by the orderbook contract
     */
    function transferTokenToOrderbook(
        address token,
        uint256 amount
    ) external isNotBlocked(token) poolExists(token) onlyOrderbook {
        require(amount > 0, "Amount must be greater than 0");
        require(token != address(0), "Invalid token address");
        PoolInfo storage pool = pools[token];
        require(pool.totalLiquidity > 0, "No liquidity");
        require(pool.totalToken >= amount, "Insufficient pool token balance");

        // Update pool balances
        pool.totalToken -= amount;
        pool.totalLiquidity -= amount;

        // Transfer tokens to orderbook
        IERC20(token).safeTransfer(msg.sender, amount);

        emit PoolBalanceUpdated(
            token,
            pool.totalEth,
            pool.totalToken,
            pool.totalLiquidity,
            pool.totalLPShares
        );
    }

    /**
     * @notice Receive ETH deposit from orderbook for order fulfillment
     * @param token The token being traded
     * @param amount The amount of ETH to deposit
     * @dev Only callable by the orderbook contract
     */
    function receiveETHFromOrderbook(
        address token,
        uint256 amount
    ) external payable isNotBlocked(token) poolExists(token) onlyOrderbook {
        require(amount > 0, "Amount must be greater than 0");
        require(msg.value == amount, "ETH amount mismatch");

        // Update pool information
        PoolInfo storage pool = pools[token];
        require(pool.totalLiquidity > 0, "No liquidity");

        // Update pool balances
        pool.totalEth += amount;
        pool.totalLiquidity += amount;

        emit ETHReceivedFromOrderbook(msg.sender, amount, token);
        emit PoolBalanceUpdated(
            token,
            pool.totalEth,
            pool.totalToken,
            pool.totalLiquidity,
            pool.totalLPShares
        );
    }

    /**
     * @notice Receive token deposit from orderbook for order fulfillment
     * @param token The token to deposit
     * @param amount The amount of tokens to deposit
     * @dev Only callable by the orderbook contract
     */
    function receiveTokenFromOrderbook(
        address token,
        uint256 amount
    ) external isNotBlocked(token) poolExists(token) onlyOrderbook {
        require(amount > 0, "Amount must be greater than 0");
        require(token != address(0), "Invalid token address");

        // Update pool information
        PoolInfo storage pool = pools[token];
        require(pool.totalLiquidity > 0, "No liquidity");

        // Transfer tokens from orderbook to pool
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update pool balances
        pool.totalToken += amount;
        pool.totalLiquidity += amount;

        emit TokenReceivedFromOrderbook(msg.sender, token, amount);
        emit PoolBalanceUpdated(
            token,
            pool.totalEth,
            pool.totalToken,
            pool.totalLiquidity,
            pool.totalLPShares
        );
    }

    /**
     * @notice Get the Uniswap V2 pair address for a given token
     * @param token Address of the token
     * @return pairAddress Address of the Uniswap V2 pair
     */
    function getPairAddress(
        address token
    ) public view returns (address pairAddress) {
        address routerAddress = gradientRegistry.router();
        require(routerAddress != address(0), "Router not set");

        IUniswapV2Router02 router = IUniswapV2Router02(routerAddress);
        address factory = router.factory();
        address weth = router.WETH();

        IUniswapV2Factory factoryContract = IUniswapV2Factory(factory);
        return factoryContract.getPair(token, weth);
    }

    /**
     * @notice Get the reserves for a token pair
     * @param token Address of the token
     * @return reserveETH ETH reserve amount
     * @return reserveToken Token reserve amount
     */
    function getReserves(
        address token
    ) public view returns (uint256 reserveETH, uint256 reserveToken) {
        address pairAddress = getPairAddress(token);
        require(pairAddress != address(0), "Pair does not exist");

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pairAddress)
            .getReserves();
        address token0 = IUniswapV2Pair(pairAddress).token0();

        (reserveETH, reserveToken) = token0 == token
            ? (reserve1, reserve0)
            : (reserve0, reserve1);
    }
}
