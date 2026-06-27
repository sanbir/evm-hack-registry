// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GradientRegistry
 * @notice Central registry for storing and managing Gradient protocol contract addresses
 * @dev This contract acts as a central point for contract address management and access control
 */
contract GradientRegistry is Ownable {
    // Contract addresses
    address public marketMakerPool;
    address public gradientToken;
    address public feeCollector;
    address public orderbook;
    address public fallbackExecutor;
    address public router; // Uniswap V2 Router address

    // Mapping for blocked tokens
    mapping(address => bool) public blockedTokens;
    mapping(address => bool) public isRewardDistributor;

    // Mapping for additional contracts that might be added later
    mapping(bytes32 => address) public additionalContracts;

    // Access control for contracts that can call certain functions
    mapping(address => bool) public authorizedContracts;

    // Mapping for authorized fulfillers
    mapping(address => bool) public authorizedFulfillers;

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

    constructor() Ownable(msg.sender) {}

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
    ) external onlyOwner {
        emit ContractAddressUpdated(
            "MarketMakerPool",
            marketMakerPool,
            _marketMakerPool
        );
        emit ContractAddressUpdated(
            "GradientToken",
            gradientToken,
            _gradientToken
        );
        emit ContractAddressUpdated(
            "FeeCollector",
            feeCollector,
            _feeCollector
        );
        emit ContractAddressUpdated("Orderbook", orderbook, _orderbook);
        emit ContractAddressUpdated(
            "FallbackExecutor",
            fallbackExecutor,
            _fallbackExecutor
        );
        emit ContractAddressUpdated("Router", router, _router);

        marketMakerPool = _marketMakerPool;
        gradientToken = _gradientToken;
        feeCollector = _feeCollector;
        orderbook = _orderbook;
        fallbackExecutor = _fallbackExecutor;
        router = _router;
    }

    /**
     * @notice Set the block status of a token
     * @param token The address of the token to set the block status of
     * @param blocked Whether the token should be blocked
     */
    function setTokenBlockStatus(
        address token,
        bool blocked
    ) external onlyOwner {
        blockedTokens[token] = blocked;
    }

    /**
     * @notice Set a reward distributor address
     * @param rewardDistributor The address of the reward distributor to authorize
     * @dev Only callable by the contract owner
     */
    function setRewardDistributor(
        address rewardDistributor
    ) external onlyOwner {
        require(rewardDistributor != address(0), "Invalid distributor address");
        isRewardDistributor[rewardDistributor] = true;
        emit RewardDistributorSet(rewardDistributor);
    }

    /**
     * @notice Set an individual main contract address
     * @param contractName Name of the contract to update
     * @param newAddress New address for the contract
     */
    function setContractAddress(
        string calldata contractName,
        address newAddress
    ) external onlyOwner {
        require(newAddress != address(0), "Invalid address");

        bytes32 nameHash = keccak256(bytes(contractName));
        address oldAddress;

        if (nameHash == keccak256(bytes("MarketMakerPool"))) {
            oldAddress = marketMakerPool;
            marketMakerPool = newAddress;
        } else if (nameHash == keccak256(bytes("GradientToken"))) {
            oldAddress = gradientToken;
            gradientToken = newAddress;
        } else if (nameHash == keccak256(bytes("FeeCollector"))) {
            oldAddress = feeCollector;
            feeCollector = newAddress;
        } else if (nameHash == keccak256(bytes("Orderbook"))) {
            oldAddress = orderbook;
            orderbook = newAddress;
        } else if (nameHash == keccak256(bytes("FallbackExecutor"))) {
            oldAddress = fallbackExecutor;
            fallbackExecutor = newAddress;
        } else if (nameHash == keccak256(bytes("Router"))) {
            oldAddress = router;
            router = newAddress;
        } else {
            revert("Invalid contract name");
        }

        emit ContractAddressUpdated(contractName, oldAddress, newAddress);
    }

    /**
     * @notice Set an additional contract address using a key
     * @param key The key to identify the contract
     * @param contractAddress The address of the contract
     */
    function setAdditionalContract(
        bytes32 key,
        address contractAddress
    ) external onlyOwner {
        require(contractAddress != address(0), "Invalid address");
        require(key != bytes32(0), "Invalid key");

        additionalContracts[key] = contractAddress;
        emit AdditionalContractSet(key, contractAddress);
    }

    /**
     * @notice Authorize or deauthorize a contract
     * @param contractAddress The address of the contract
     * @param authorized Whether the contract should be authorized
     */
    function setContractAuthorization(
        address contractAddress,
        bool authorized
    ) external onlyOwner {
        require(contractAddress != address(0), "Invalid address");
        authorizedContracts[contractAddress] = authorized;
        emit ContractAuthorized(contractAddress, authorized);
    }

    /**
     * @notice Check if a contract is authorized
     * @param contractAddress The address to check
     * @return bool Whether the contract is authorized
     */
    function isContractAuthorized(
        address contractAddress
    ) external view returns (bool) {
        return authorizedContracts[contractAddress];
    }

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
        )
    {
        return (
            marketMakerPool,
            gradientToken,
            feeCollector,
            orderbook,
            fallbackExecutor,
            router
        );
    }

    /**
     * @notice Modifier to check if caller is an authorized contract
     */
    modifier onlyAuthorized() {
        require(authorizedContracts[msg.sender], "Not authorized");
        _;
    }

    /**
     * @notice Get the orderbook contract address
     * @return address The orderbook contract address
     */
    function getOrderbook() external view returns (address) {
        return orderbook;
    }

    /**
     * @notice Get the fallback executor contract address
     * @return address The fallback executor contract address
     */
    function getFallbackExecutor() external view returns (address) {
        return fallbackExecutor;
    }

    /**
     * @notice Get the router contract address
     * @return address The router contract address
     */
    function getRouter() external view returns (address) {
        return router;
    }

    /**
     * @notice Authorize or deauthorize a fulfiller
     * @param fulfiller The address of the fulfiller to authorize
     * @param status The status of the fulfiller
     */
    function authorizeFulfiller(
        address fulfiller,
        bool status
    ) external onlyOwner {
        require(fulfiller != address(0), "Invalid fulfiller address");
        authorizedFulfillers[fulfiller] = status;
        emit FulfillerAuthorized(fulfiller, status);
    }

    /**
     * @notice Check if an address is an authorized fulfiller
     * @param fulfiller The address to check
     * @return bool Whether the address is an authorized fulfiller
     */
    function isAuthorizedFulfiller(
        address fulfiller
    ) external view returns (bool) {
        return authorizedFulfillers[fulfiller];
    }
}
