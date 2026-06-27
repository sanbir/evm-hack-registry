// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IGradientMarketMakerPool
 * @notice Interface for the GradientMarketMakerPool contract
 */
interface IGradientMarketMakerPool {
    // Structs
    struct MarketMaker {
        uint256 tokenAmount;
        uint256 ethAmount;
        uint256 lpShares;
        uint256 rewardDebt;
        uint256 pendingReward;
    }

    struct PoolInfo {
        uint256 totalEth;
        uint256 totalToken;
        uint256 totalLiquidity;
        uint256 totalLPShares;
        uint256 accRewardPerShare;
        uint256 rewardBalance;
        address uniswapPair;
    }

    // Events
    event ETHTransferredToOrderbook(
        address indexed orderbook,
        uint256 amount,
        address indexed token
    );
    event TokenTransferredToOrderbook(
        address indexed orderbook,
        address indexed token,
        uint256 amount
    );
    event ETHReceivedFromOrderbook(
        address indexed orderbook,
        uint256 amount,
        address indexed token
    );
    event TokenReceivedFromOrderbook(
        address indexed orderbook,
        address indexed token,
        uint256 amount
    );

    /**
     * @notice Transfer ETH to orderbook for order fulfillment
     * @param token The token being traded
     * @param amount The amount of ETH to transfer
     */
    function transferETHToOrderbook(address token, uint256 amount) external;

    /**
     * @notice Transfer tokens to orderbook for order fulfillment
     * @param token The token to transfer
     * @param amount The amount of tokens to transfer
     */
    function transferTokenToOrderbook(address token, uint256 amount) external;

    /**
     * @notice Receive ETH deposit from orderbook for order fulfillment
     * @param token The token being traded
     * @param amount The amount of ETH to deposit
     */
    function receiveETHFromOrderbook(
        address token,
        uint256 amount
    ) external payable;

    /**
     * @notice Receive token deposit from orderbook for order fulfillment
     * @param token The token to deposit
     * @param amount The amount of tokens to deposit
     */
    function receiveTokenFromOrderbook(address token, uint256 amount) external;

    /**
     * @notice Receive fee distribution from orderbook
     * @param token The token for which fees are being distributed
     */
    function receiveFeeDistribution(address token) external payable;

    /**
     * @notice Allows users to provide liquidity to a pool
     * @param token Address of the token to provide liquidity for
     * @param tokenAmount Amount of tokens to deposit
     * @param minTokenAmount Minimum amount of tokens to accept (slippage protection)
     */
    function provideLiquidity(
        address token,
        uint256 tokenAmount,
        uint256 minTokenAmount
    ) external payable;

    /**
     * @notice Allows market maker to withdraw liquidity and claim pending rewards
     * @param token Address of the token to withdraw from
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     */
    function withdrawLiquidity(address token, uint256 shares) external;

    /**
     * @notice Claims pending rewards for caller
     * @param token Address of the token pool to claim rewards from
     */
    function claimReward(address token) external;

    /**
     * @notice Gets pool information for a specific token
     * @param token Address of the token to get pool info for
     * @return PoolInfo struct containing pool details
     */
    function getPoolInfo(address token) external view returns (PoolInfo memory);

    /**
     * @notice Gets a user's current share percentage of the pool
     * @param token Address of the token
     * @param user Address of the user
     * @return sharePercentage User's share percentage in basis points (10000 = 100%)
     */
    function getUserSharePercentage(
        address token,
        address user
    ) external view returns (uint256 sharePercentage);

    /**
     * @notice Gets a user's LP shares for a specific token
     * @param token Address of the token
     * @param user Address of the user
     * @return lpShares User's LP shares
     */
    function getUserLPShares(
        address token,
        address user
    ) external view returns (uint256 lpShares);

    /**
     * @notice Get the Uniswap V2 pair address for a given token
     * @param token Address of the token
     * @return pairAddress Address of the Uniswap V2 pair
     */
    function getPairAddress(
        address token
    ) external view returns (address pairAddress);

    /**
     * @notice Get the reserves for a token pair
     * @param token Address of the token
     * @return reserveETH ETH reserve amount
     * @return reserveToken Token reserve amount
     */
    function getReserves(
        address token
    ) external view returns (uint256 reserveETH, uint256 reserveToken);
}
