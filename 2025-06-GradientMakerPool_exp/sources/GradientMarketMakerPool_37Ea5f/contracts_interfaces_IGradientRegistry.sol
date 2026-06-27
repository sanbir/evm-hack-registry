// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IGradientRegistry
 * @notice Interface for the GradientRegistry contract
 */
interface IGradientRegistry {
    // Events
    event ContractAddressUpdated(
        string indexed contractName,
        address indexed oldAddress,
        address indexed newAddress
    );
    event AdditionalContractSet(
        bytes32 indexed key,
        address indexed contractAddress
    );
    event ContractAuthorized(address indexed contractAddress, bool authorized);
    event RewardDistributorSet(address indexed rewardDistributor);
    event FulfillerAuthorized(address indexed fulfiller, bool status);

    /**
     * @notice Set the main contract addresses
     * @param _marketMakerPool Address of the MarketMakerPool contract
     * @param _gradientToken Address of the Gradient token contract
     * @param _feeCollector Address of the fee collector contract
     * @param _orderbook Address of the Orderbook contract
     * @param _fallbackExecutor Address of the FallbackExecutor contract
     * @param _router Address of the Uniswap V2 Router contract
     */
    function setMainContracts(
        address _marketMakerPool,
        address _gradientToken,
        address _feeCollector,
        address _orderbook,
        address _fallbackExecutor,
        address _router
    ) external;

    /**
     * @notice Set an individual main contract address
     * @param contractName Name of the contract to update
     * @param newAddress New address for the contract
     */
    function setContractAddress(
        string calldata contractName,
        address newAddress
    ) external;

    /**
     * @notice Set an additional contract address using a key
     * @param key The key to identify the contract
     * @param contractAddress The address of the contract
     */
    function setAdditionalContract(
        bytes32 key,
        address contractAddress
    ) external;

    /**
     * @notice Set the block status of a token
     * @param token The address of the token to set the block status of
     * @param blocked Whether the token should be blocked
     */
    function setTokenBlockStatus(address token, bool blocked) external;

    /**
     * @notice Set a reward distributor address
     * @param rewardDistributor The address of the reward distributor to authorize
     */
    function setRewardDistributor(address rewardDistributor) external;

    /**
     * @notice Authorize or deauthorize a fulfiller
     * @param fulfiller The address of the fulfiller to authorize
     * @param status The status of the fulfiller
     */
    function authorizeFulfiller(address fulfiller, bool status) external;

    /**
     * @notice Check if a contract is authorized
     * @param contractAddress The address to check
     * @return bool Whether the contract is authorized
     */
    function isContractAuthorized(
        address contractAddress
    ) external view returns (bool);

    /**
     * @notice Check if an address is an authorized fulfiller
     * @param fulfiller The address to check
     * @return bool Whether the address is an authorized fulfiller
     */
    function isAuthorizedFulfiller(
        address fulfiller
    ) external view returns (bool);

    /**
     * @notice Get all main contract addresses
     * @return _marketMakerPool Address of the MarketMakerPool contract
     * @return _gradientToken Address of the Gradient token contract
     * @return _feeCollector Address of the fee collector contract
     * @return _orderbook Address of the Orderbook contract
     * @return _fallbackExecutor Address of the FallbackExecutor contract
     * @return _router Address of the Uniswap V2 Router contract
     */
    function getAllMainContracts()
        external
        view
        returns (
            address _marketMakerPool,
            address _gradientToken,
            address _feeCollector,
            address _orderbook,
            address _fallbackExecutor,
            address _router
        );

    // View functions for individual contract addresses
    function marketMakerPool() external view returns (address);

    function gradientToken() external view returns (address);

    function feeCollector() external view returns (address);

    function orderbook() external view returns (address);

    function fallbackExecutor() external view returns (address);

    function router() external view returns (address);

    // View functions for mappings
    function blockedTokens(address token) external view returns (bool);

    function additionalContracts(bytes32 key) external view returns (address);

    function authorizedContracts(
        address contractAddress
    ) external view returns (bool);

    function isRewardDistributor(
        address rewardDistributor
    ) external view returns (bool);

    function authorizedFulfillers(
        address fulfiller
    ) external view returns (bool);
}
