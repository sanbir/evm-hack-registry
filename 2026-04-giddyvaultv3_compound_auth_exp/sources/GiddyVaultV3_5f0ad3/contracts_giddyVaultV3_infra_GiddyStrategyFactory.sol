// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title GiddyStrategyFactory
 * @notice Factory contract for deploying Giddy strategies using BeaconProxy pattern
 * @dev Implements BeaconProxy pattern for gas-efficient strategy deployment
 *      Implements centralized strategy management with pause controls
 */
contract GiddyStrategyFactory is OwnableUpgradeable {

    /// @notice Contract version for tracking upgrades
    string public constant VERSION = "1.1.0";

    // ============ State Variables ============

    /// @notice Instance mapping to strategy name with version
    mapping (string => UpgradeableBeacon) public instances;

    /// @notice Deployed strategy types
    string[] public strategyTypes;

    /// @notice Mapping of keeper addresses
    mapping(address => bool) public keepers;

    /// @notice Pause state by strategy name
    mapping(string => bool) public strategyPause;

    /// @notice The fee config address
    address public feeConfig;

    /// @notice The adapter manager address
    address public adapterManager;

    /// @notice The authorized signer address for vault operations
    address public authorizedSigner;

    /// @notice Global pause state for all strategies
    bool public globalPause;

    /// @notice Mapping of authorized signer addresses for vault operations
    mapping(address => bool) public authorizedSigners;

    // ============ Errors ============

    error NotManager();

    // ============ Modifiers ============

    /// @notice Throws if called by any account other than the owner or a keeper
    modifier onlyManager() {
        if (msg.sender != owner() && !keepers[msg.sender]) revert NotManager();
        _;
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the factory
     * @param _owner Owner of the contract
     */
    function initialize(address _owner) external initializer {
        require(_owner != address(0), "Invalid owner address");
        __Ownable_init(_owner);
    }

        // ============ Core Functions ============

    /**
     * @notice Add a new strategy beacon to the factory
     * @param _strategyName Name of the strategy
     * @param _implementation Implementation address
     */
    function addStrategyBeacon(string calldata _strategyName, address _implementation) external onlyManager {
        require(address(instances[_strategyName]) == address(0), "Strategy type already exists");

        instances[_strategyName] = new UpgradeableBeacon(_implementation, address(this));
        strategyTypes.push(_strategyName);
    }

    /**
     * @notice Create a new strategy proxy
     * @param _strategyName Type of strategy to create
     * @return strategy Address of the created strategy proxy
     */
    function createStrategyProxy(string calldata _strategyName) external onlyManager returns (address strategy) {
        UpgradeableBeacon instance = instances[_strategyName];
        require(address(instance) != address(0), "Strategy type not found");
        
        BeaconProxy proxy = new BeaconProxy(address(instance), "");
        strategy = address(proxy);
        return strategy;
    }

    /**
     * @notice Upgrade the implementation of a strategy beacon
     * @param _strategyName Name of the strategy
     * @param _newImplementation New implementation address
     */
    function upgradeStrategyBeacon(string calldata _strategyName, address _newImplementation) external onlyOwner {
        UpgradeableBeacon instance = instances[_strategyName];
        require(address(instance) != address(0), "Strategy type not found");
        
        instance.upgradeTo(_newImplementation);
    }

    // ============ Pause Management ============

    /**
     * @notice Set global pause state
     * @param _paused Whether to pause all strategies
     */
    function setGlobalPause(bool _paused) external onlyManager {
        globalPause = _paused;
    }

    /**
     * @notice Set strategy-specific pause state
     * @param strategyName Name of the strategy
     * @param _paused Whether to pause the strategy
     */
    function setStrategyPause(string calldata strategyName, bool _paused) external onlyManager {
        strategyPause[strategyName] = _paused;
    }

    // ============ Management Functions ============

    /**
     * @notice Add a keeper address
     * @param _keeper Keeper address to add
     */
    function addKeeper(address _keeper) external onlyOwner {
        require(_keeper != address(0), "Invalid keeper address");
        require(!keepers[_keeper], "Keeper already exists");
        keepers[_keeper] = true;
    }

    /**
     * @notice Remove a keeper address
     * @param _keeper Keeper address to remove
     */
    function removeKeeper(address _keeper) external onlyOwner {
        require(keepers[_keeper], "Keeper does not exist");
        keepers[_keeper] = false;
    }

    /**
     * @notice Check if an address is a keeper
     * @param _keeper Address to check
     * @return isKeeper Whether the address is a keeper
     */
    function isKeeper(address _keeper) external view returns (bool) {
        return keepers[_keeper];
    }

    /**
     * @notice Set the fee config address
     * @param _feeConfig New fee config address
     */
    function setFeeConfig(address _feeConfig) external onlyOwner {
        require(_feeConfig != address(0), "Invalid fee config address");
        feeConfig = _feeConfig;
    }

    /**
     * @notice Set the adapter manager address
     * @param _adapterManager New adapter manager address
     */
    function setAdapterManager(address _adapterManager) external onlyOwner {
        require(_adapterManager != address(0), "Invalid adapter manager address");
        adapterManager = _adapterManager;
    }

    /**
     * @notice Set the authorized signer address
     * @param _authorizedSigner New authorized signer address
     * @param _authorized Whether the signer is authorized
     */
    function setAuthorizedSigner(address _authorizedSigner, bool _authorized) external onlyOwner {
      authorizedSigners[_authorizedSigner] = _authorized;
    }

    /**
     * @notice Check if an address is an authorized signer
     * @param _signer Address to check
     * @return Whether the address is an authorized signer
     */
    function isAuthorizedSigner(address _signer) external view returns (bool) {
      return authorizedSigners[_signer];
    }

    // ============ View Functions ============

    /**
     * @notice Get the implementation of a strategy type
     * @param _strategyName Name of the strategy
     * @return Implementation address
     */
    function getImplementation(string calldata _strategyName) external view returns (address) {
        return instances[_strategyName].implementation();
    }

    /**
     * @notice Get the array of deployed strategy types
     * @return Array of deployed strategy types
     */
    function getStrategyTypes() external view returns (string[] memory) {
        return strategyTypes;
    }
}