// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity >=0.8.0;

import {IInterchainGasPaymaster} from "./interfaces/IInterchainGasPaymaster.sol";
import {IMailbox} from "./interfaces/IMailbox.sol";
import {IPostDispatchHook} from "./interfaces/hooks/IPostDispatchHook.sol";
import {IInterchainSecurityModule, ISpecifiesInterchainSecurityModule} from "./interfaces/IInterchainSecurityModule.sol";
import {TypeCasts} from "./libs/TypeCasts.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IDIAOracleV2 {
    function getValue(
        string memory key
    ) external view returns (uint128, uint128);
}

using TypeCasts for address;

error ZeroAddress();
error InvalidChainConfig();
error ChainNotConfigured(uint32 chainId);
error OracleError(string key);

error NotAuthorized(address account);
error ExistingAdmin(address account);

error CannotRemoveLastOwner();

// @title OracleTrigger
/// @notice This contract manages interchain oracle requests and dispatching price updates.Whitelisted in Hyperlane
/// @dev Provides access control for managing chains and secure dispatching mechanisms.
contract OracleTrigger is
    AccessControlEnumerable,
    ISpecifiesInterchainSecurityModule,
    ReentrancyGuard
{
    struct ChainConfig {
        address RecipientAddress;
    }
    /// @notice Address of the Interchain Security Module (ISM).
    IInterchainSecurityModule public interchainSecurityModule;

    /// @notice Address of the mailbox contract responsible for interchain messaging.
    address private mailBox;

    /// @notice Mapping of chain IDs to their corresponding recipient addresses.
    mapping(uint32 => ChainConfig) public chains;

    /// @notice Role identifier for contract owners.
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    /// @notice Address of the DIA oracle metadata contract.
    address public metadataContract;

    /// @notice Emitted when a new chain is added.
    /// @param chainId The chain ID of the newly added chain.
    /// @param RecipientAddress Address of the recipient contract on the chain.
    event ChainAdded(uint32 indexed chainId, address RecipientAddress);
    /// @notice Emitted when a chain configuration is updated.
    /// @param chainId The chain ID being updated.
    /// @param RecipientAddress New recipient address.
    event ChainUpdated(uint32 indexed chainId, address RecipientAddress);

    /// @notice Emitted when a message is dispatched to a destination chain.
    /// @param chainId The destination chain ID.
    /// @param recipientAddress The recipient contract address on the destination chain.
    /// @param messageId The message ID.
    event MessageDispatched(
        uint32 chainId,
        address recipientAddress,
        bytes32 indexed messageId
    );

    /// @notice Emitted when an owner is added.
    /// @param account The address of the new owner.
    /// @param addedBy The address that added the new owner.
    /// @param timestamp The timestamp of the addition.
    event OwnerAdded(
        address indexed account,
        address indexed addedBy,
        uint256 timestamp
    );

    /// @notice Emitted when an owner is removed.
    /// @param account The address of the removed owner.
    /// @param removedBy The address that removed the owner.
    /// @param timestamp The timestamp of the removal.
    event OwnerRemoved(
        address indexed account,
        address indexed removedBy,
        uint256 timestamp
    );

    /// @notice Emitted when the mailbox contract address is updated.
    /// @param newMailbox The new mailbox contract address.
    event MailboxUpdated(address indexed newMailbox);
    /// @notice Emitted when the interchain security module (ISM) address is updated.
    /// @param newModule The new ISM address.
    event InterchainSecurityModuleUpdated(address indexed newModule);

    /// @notice Emitted when the metadata contract address is updated.
    /// @param newMetadata The new metadata contract address.
    event MetadataContractUpdated(address indexed newMetadata);

    /// @notice Ensures that the provided address is not a zero address.
    modifier validateAddress(address _address) {
        if (_address == address(0)) revert ZeroAddress();
        _;
    }

    /// @notice Ensures that the given chain is configured.
    modifier validateChain(uint32 _chainId) {
        if (chains[_chainId].RecipientAddress == address(0))
            revert ChainNotConfigured(_chainId);
        _;
    }

    /// @notice Ensures that only contract owners can execute the function.
    modifier onlyOwner() {
        if (!hasRole(OWNER_ROLE, msg.sender)) revert NotAuthorized(msg.sender);
        _;
    }

    /// @notice Contract constructor that initializes the contract and assigns the deployer as the first owner.
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OWNER_ROLE, msg.sender);
    }

    /// @notice Adds a new chain recipient address.
    /// @param chainId The chain ID to be added.
    /// @param recipientAddress The recipient address for the chain.
    function addChain(
        uint32 chainId,
        address recipientAddress
    ) public onlyOwner validateAddress(recipientAddress) {
        chains[chainId] = ChainConfig(recipientAddress);
        emit ChainAdded(chainId, recipientAddress);
    }

    
    /// @notice Updates the recipient address for a specific chain.
    /// @param chainId The chain ID to be updated.
    /// @param recipientAddress The new recipient address.
    function updateChain(
        uint32 chainId,
        address recipientAddress
    )
        public
        onlyOwner
        validateAddress(recipientAddress)
        validateChain(chainId)
    {
        chains[chainId] = ChainConfig(recipientAddress);
        emit ChainUpdated(chainId, recipientAddress);
    }

    /// @notice Returns the recipient address for a given chain.
    /// @param _chainId The chain ID to query.
    function viewChain(
        uint32 _chainId
    ) public view validateChain(_chainId) returns (address) {
        return chains[_chainId].RecipientAddress;
    }

    /// @notice Updates the metadata contract address.
    /// @param newMetadata The new metadata contract address.
    function updateMetadataContract(
        address newMetadata
    ) external onlyOwner validateAddress(newMetadata) {
        metadataContract = newMetadata;
        emit MetadataContractUpdated(newMetadata);
    }

    /**
     *  @notice Dispatches a message to a configured destination chain.
     *  @param _destinationDomain The destination chain ID.
     *  @param key The key used to fetch the oracle value.
     */

    function dispatchToChain(
        uint32 _destinationDomain,
        string memory key
    )
        external
        payable
        onlyOwner
        validateChain(_destinationDomain)
        validateAddress(mailBox)
        nonReentrant
    {
        ChainConfig storage config = chains[_destinationDomain];

        (uint128 currValue, uint128 currTimestamp) = _getOracleValue(key);

        bytes memory messageBody = abi.encode(key, currTimestamp, currValue);
        bytes32 messageId = IMailbox(mailBox).dispatch{value: msg.value}(
            _destinationDomain,
            config.RecipientAddress.addressToBytes32(),
            messageBody
        );

        emit MessageDispatched(
            _destinationDomain,
            config.RecipientAddress,
            messageId
        );
    }

    /// @notice Dispatches a message to a configured destination chain.
    /// @param _destinationDomain The destination chain ID.
    /// @param key The key used to fetch the oracle value.
    function dispatch(
        uint32 _destinationDomain,
        address recipientAddress,
        string memory key
    )
        external
        payable
        onlyOwner
        nonReentrant
        validateAddress(mailBox)
        validateAddress(recipientAddress)
    {
        (uint128 currValue, uint128 currTimestamp) = _getOracleValue(key);

        bytes memory messageBody = abi.encode(key, currTimestamp, currValue);

        bytes32 messageId = IMailbox(mailBox).dispatch{value: msg.value}(
            _destinationDomain,
            recipientAddress.addressToBytes32(),
            messageBody
        );

        emit MessageDispatched(_destinationDomain, recipientAddress, messageId);
    }

    /**
     * @notice Sets the interchain security module.
     * @param _ism The new ISM address.
     */
    function setInterchainSecurityModule(
        address _ism
    ) external onlyOwner validateAddress(_ism) {
        interchainSecurityModule = IInterchainSecurityModule(_ism);
        emit InterchainSecurityModuleUpdated(_ism);
    }

    /**
     * @notice Sets the mailbox address.
     * @param _mailbox The new mailbox address.
     */
    function setMailBox(
        address _mailbox
    ) external onlyOwner validateAddress(_mailbox) {
        mailBox = _mailbox;
        emit MailboxUpdated(_mailbox);
    }

    /**
     * @notice Gets the mailbox address.
     */
    function getMailBox(
    ) external view returns    (address) {
       return mailBox;
    }

    /**
     * @notice Fetches value from the oracle.
     * @param key The oracle key to query.
     */

    function _getOracleValue(
        string memory key
    ) internal view returns (uint128, uint128) {
        if (metadataContract == address(0)) revert ZeroAddress();

        try IDIAOracleV2(metadataContract).getValue(key) returns (
            uint128 value,
            uint128 timestamp
        ) {
            return (value, timestamp);
        } catch {
            revert OracleError(key);
        }
    }

    /**
     * @notice Adds an owner.
     */
    function addOwner(
        address _newOwner
    ) external validateAddress(_newOwner) onlyOwner {
        if (hasRole(OWNER_ROLE, _newOwner)) revert ExistingAdmin(_newOwner);
        grantRole(OWNER_ROLE, _newOwner);
        emit OwnerAdded(_newOwner, msg.sender, block.timestamp);
    }

    /**
     * @notice Removes an owner but ensures at least one remains.
     */
    function removeOwner(
        address _owner
    ) external validateAddress(_owner) onlyOwner {
        if (getRoleMemberCount(OWNER_ROLE) <= 1) revert CannotRemoveLastOwner();
        revokeRole(OWNER_ROLE, _owner);
        emit OwnerRemoved(_owner, msg.sender, block.timestamp);
    }

    /**
     * @notice Checks if an address is an owner.
     */
    function isOwner(address _account) external view returns (bool) {
        return hasRole(OWNER_ROLE, _account);
    }

    /**
     * @notice Returns a list of all owners.
     */
    function getOwners() external view returns (address[] memory) {
        uint256 ownerCount = getRoleMemberCount(OWNER_ROLE);
        address[] memory owners = new address[](ownerCount);

        for (uint256 i = 0; i < ownerCount; i++) {
            owners[i] = getRoleMember(OWNER_ROLE, i);
        }

        return owners;
    }
}
