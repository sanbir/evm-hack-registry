// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IGasOracle {
    function CHAIN_ID() external view returns (uint256);
    /**
     * @notice Returns the transaction fee in the source chain's native currency.
     * @param chainId Destination chain ID.
     * @param gasAmount Estimated gas usage on the destination chain.
     * @return Fee in source chain's native currency (scaled by sourceChain NATIVE_TOKEN_DECIMALS).
     */
    function getTransactionFeeInNative(uint256 chainId, uint256 gasAmount) external view returns (uint256);

    /**
     * @notice Returns the transaction fee in stable currency.
     * @param chainId Destination chain ID.
     * @param gasAmount Estimated gas usage on the destination chain.
     * @return Fee in stable currency (always 18 decimals).
     */
    function getTransactionFeeInStable(uint256 chainId, uint256 gasAmount) external view returns (uint256);

    /**
     * @notice Converts an amount of native currency from a specific chain to stable currency.
     * @param chainId Chain ID of the native currency.
     * @param amount Amount in native currency.
     * @return Equivalent amount in stable currency (always 18 decimals).
     */
    function convertNativeToStable(uint256 chainId, uint256 amount) external view returns (uint256);

    /**
     * @notice Converts an amount of stable currency to source chain's native currency.
     * @param amount Amount in stable currency (18 decimals).
     * @return Equivalent amount in source chain's native currency (scaled by sourceChain NATIVE_TOKEN_DECIMALS).
     */
    function convertStableToNative(uint256 amount) external view returns (uint256);

    /**
     * @notice Returns oracle data for a specific chain.
     * @param chainId Chain ID to query.
     * @return nativePrice Native token price in stable currency (always 18 decimals).
     * @return gasPrice Current gas price on the destination chain (in wei).
     */
    function chainData(uint256 chainId) external view returns (uint256 nativePrice, uint256 gasPrice);
}
