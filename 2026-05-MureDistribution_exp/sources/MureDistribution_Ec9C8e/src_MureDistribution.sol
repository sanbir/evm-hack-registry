// SPDX-License-Identifier: BUSL 1.1
pragma solidity 0.8.22;

import {
    ERC165Upgradeable, IERC165
} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {
    AccessControlUpgradeable,
    IAccessControl
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {PoolMetadata, PoolState} from "./interfaces/PoolMetadata.sol";
import {Distributable} from "./interfaces/Distributable.sol";
import {MureErrors} from "./libraries/MureErrors.sol";
import {POOL_OPERATOR_ROLE} from "./shared/Constants.sol";

/// @title MureDistribution
/// @author Mure
/// @notice Distribution contract for distributing assets described by `PoolMetadata` contracts.
/// @dev Recommended use is with a `MurePool` contract, where off-chain signatures are provided for
/// permits and saving gas by depending on off-chain compute power for complex computations based on
/// on-chain state.
contract MureDistribution is
    EIP712Upgradeable,
    ERC165Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    Distributable
{
    /// @custom:storage-location erc7201:mure.MureDistribution
    struct MureDistributionStorage {
        mapping(bytes32 => DistributionHistory) distributions;
        mapping(address => uint24) nonces;
    }

    /**
     * @dev Role allows user to create and update pools along with pool administration
     */
    bytes32 public constant DISTRIBUTION_ADMIN_ROLE = keccak256("DISTRIBUTION_ADMIN");

    /**
     * @dev Hash for storage location
     * `keccak256(abi.encode(uint256(keccak256("mure.MureDistribution")) - 1)) & ~bytes32(uint256(0xff))`
     */
    bytes32 private constant MureDistributionStorageLocation =
        0xcb2c43c8a077042ee388281b9a5a398915ca6047194d75b071075a7b241a5800;

    /**
     * @dev Struct hash for validating deposits
     * `keccak256("Distribution(address token,address source,string pool,address repository,address depositor,address claimer,uint256 amount,uint256 deadline,uint24 nonce)")`
     */
    bytes32 private constant DISTRIBUTION_HASH = 0xc947aa90aaf074203df95a7de07adb71025f14e165fb180a3c83663110a02ce1;

    modifier distributable(DistributionRecord calldata distribution) {
        if (distribution.deadline < block.timestamp) {
            revert MureErrors.SignatureExpired();
        }
        if (!ERC165Checker.supportsInterface(distribution.source, type(PoolMetadata).interfaceId)) {
            revert UnsupportedSource();
        }
        _;
    }

    modifier validManager(address source) {
        if (!ERC165Checker.supportsInterface(source, type(IAccessControl).interfaceId)) {
            revert UnsupportedSource();
        }
        // TODO: Figure out elegant solution to not have duplicate info
        if (!IAccessControl(source).hasRole(POOL_OPERATOR_ROLE, _msgSender())) {
            revert MureErrors.Unauthorized();
        }
        _;
    }

    function initialize(string calldata name, string calldata version, address owner) external initializer {
        __EIP712_init(name, version);
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(DISTRIBUTION_ADMIN_ROLE, owner);
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC165Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return interfaceId == type(Distributable).interfaceId || super.supportsInterface(interfaceId);
    }

    function distribute(DistributionRecord calldata distribution, bytes calldata signature) external {
        _distribute(distribution, _msgSender(), signature);
    }

    function distribute(DistributionRecord calldata distribution, address to, bytes calldata signature) external {
        _distribute(distribution, to, signature);
    }

    /**
     * @notice Moves a distribution record from one depositor to another.
     * @dev Only used for moving complete distributions in cases such as `from` being a compromised wallet.
     * @param source the address to the application contract where the deposit information exists
     * @param poolName the name of the pool where the deposit was conducted
     * @param from the address of the original depositor
     * @param to the address of the new depositor
     */
    function moveDistribution(address source, string calldata poolName, address from, address to)
        external
        validManager(source)
    {
        MureDistributionStorage storage $ = _getDistributionStorage();
        bytes32 fromDistributionKey = _encodeDistributionKey(source, poolName, from);
        bytes32 toDistributionKey = _encodeDistributionKey(source, poolName, to);
        if ($.distributions[fromDistributionKey].distributed == 0) {
            revert Undistributed();
        }
        $.distributions[toDistributionKey].distributed = $.distributions[fromDistributionKey].distributed;
        delete $.distributions[fromDistributionKey].distributed;

        emit Move(source, from, to, poolName);
    }

    /**
     * @notice Read distribution history of `depositor` in the designated `source` and `poolName`
     * @param source the address of the pooling contract
     * @param poolName the name pf the pool
     * @param depositor the address of the depositor
     */
    function distribution(address source, string calldata poolName, address depositor)
        external
        view
        returns (DistributionHistory memory)
    {
        MureDistributionStorage storage $ = _getDistributionStorage();
        bytes32 distributionKey = _encodeDistributionKey(source, poolName, depositor);
        return $.distributions[distributionKey];
    }

    /**
     * @notice Read nonce of `depositor`
     * @param depositor the address of the depositor
     */
    function nonce(address depositor) external view returns (uint24) {
        return _getDistributionStorage().nonces[depositor];
    }

    /**
     * @dev Assumes that the `token` address is a valid `ERC20` token as the standard doesn't
     *  depend on `ERC165`. Make sure that the token is valid to avoid reverts without error codes
     */
    function _distribute(DistributionRecord calldata distribution, address to, bytes calldata signature)
        internal
        distributable(distribution)
        nonReentrant
    {
        PoolMetadata source = PoolMetadata(distribution.source);
        PoolState memory poolState = source.poolState(distribution.poolName);

        _verifySignature(distribution, poolState.signer, to, signature);

        _transferAssets(distribution, to);

        emit Distribution(
            distribution.token,
            distribution.source,
            distribution.depositor,
            distribution.repository,
            distribution.poolName,
            distribution.amount
        );
    }

    /**
     * @dev Generates a struct hash for a distribution.
     * @param distribution the distribution information
     */
    function _hashDistribution(DistributionRecord calldata distribution, address to) private view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    DISTRIBUTION_HASH,
                    distribution.token,
                    distribution.source,
                    keccak256(bytes(distribution.poolName)),
                    distribution.repository,
                    distribution.depositor,
                    to,
                    distribution.amount,
                    distribution.deadline,
                    _getDistributionStorage().nonces[distribution.depositor]
                )
            )
        );
    }

    function _transferAssets(DistributionRecord calldata distribution, address to) internal {
        MureDistributionStorage storage $ = _getDistributionStorage();
        bytes32 distributionKey =
            _encodeDistributionKey(distribution.source, distribution.poolName, distribution.depositor);

        ++$.nonces[distribution.depositor];
        $.distributions[distributionKey].distributed += distribution.amount;

        IERC20(distribution.token).transferFrom(distribution.repository, to, distribution.amount);
    }

    function _encodeDistributionKey(address source, string calldata poolName, address depositor)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(source, poolName, depositor));
    }

    function _verifySignature(DistributionRecord calldata distribution, address signer, address to, bytes calldata sig)
        private
        view
    {
        if (!SignatureChecker.isValidSignatureNow(signer, _hashDistribution(distribution, to), sig)) {
            revert MureErrors.Unauthorized();
        }
    }

    /**
     * @dev Retrieves the storage for the pool metrics.
     */
    function _getDistributionStorage() private pure returns (MureDistributionStorage storage $) {
        assembly {
            $.slot := MureDistributionStorageLocation
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DISTRIBUTION_ADMIN_ROLE) {}
}
