// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import "./base/ModuleManager.sol";
import "./base/SessionManager.sol";
import "./base/FallbackManager.sol";
import "./base/SecurityManager.sol";
import "./common/Singleton.sol";
import "./common/EtherPaymentFallback.sol";
import "./interfaces/IERC20Paymaster.sol";
import "./interfaces/IModule.sol";
import "./interfaces/ISignatureValidator.sol";
import "./eip4337/core/BaseAccount.sol";
import "./eip4337/interfaces/IEntryPoint.sol";
import "./common/Enum.sol";
import "./chain/ISodiumAuth.sol";
import "./securityengine/IUserOperationValidator.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

struct Transaction {
    Enum.Operation op; // Performs delegatecall
    bool revertOnError; // Reverts transaction bundle if tx fails
    uint256 gasLimit; // Maximum gas to be forwarded
    address target; // Address of the contract to call
    uint256 value; // Amount of ETH to pass with the call
    bytes data; // calldata to pass
}

contract Sodium is
    Singleton,
    ModuleManager,
    SessionManager,
    FallbackManager,
    SecurityManager,
    BaseAccount,
    EtherPaymentFallback,
    ISignatureValidatorConstants
{
    string public constant VERSION = "0.0.1";
    bytes32 public constant _DELEGATE_AURH_TYPEHASH =
        keccak256("Delegate(address trustee,uint64 delegateExpires)");

    // keccak256(
    //     "EIP712Domain(uint256 chainId,address verifyingContract)"
    // );
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
        0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;

    bool private initialized;
    address public immutable _entryPoint;

    // This constructor ensures that this contract can only be used as a master copy for Proxy contracts
    constructor(IEntryPoint entryPoint_) {
        _entryPoint = address(entryPoint_);
    }

    function setup(
        ISodiumAuth _sodiumAuth,
        address _fallbackHandler,
        address _opValidator,
        bytes32 _salt
    ) public {
        require(!initialized, "Already initialized");
        require(_fallbackHandler != address(0), "Required fallback handler");
        initialized = true;
        internalSetFallbackHandler(_fallbackHandler);
        internalSetSodiumNetworkAuth(_sodiumAuth);
        internalWriteUserOperationValidator(_opValidator);
        salt = _salt;
    }

    function entryPoint() public view override returns (IEntryPoint) {
        return IEntryPoint(_entryPoint);
    }

    function upgradeTo(Sodium newSingleton) external authorized {
        require(newSingleton.isSodiumSingleton(), "Not a Sodium singleton");
        _setSingleton(address(newSingleton));
    }

    function _approvePaymasterToken(UserOperation calldata userOp) private {
        bytes calldata paymasterAndData = userOp.paymasterAndData;
        if (paymasterAndData.length != 20 + 4 + 20) {
            return;
        } else if (bytes4(paymasterAndData[20:24]) == bytes4(0x095ea7b3)) {
            IERC20Paymaster paymaster = IERC20Paymaster(
                address(bytes20(paymasterAndData[:20]))
            );

            IERC20Metadata payToken = IERC20Metadata(
                address(bytes20(paymasterAndData[24:]))
            );

            (uint256 miniAllowance, uint256 suggestApproveValue) = paymaster
                .getTokenAllowanceCast(payToken);

            if (
                payToken.allowance(address(this), address(paymaster)) <
                miniAllowance
            ) {
                payToken.approve(address(paymaster), suggestApproveValue);
            }
        }
    }

    /**
     * Validate user's signature and nonce.
     * subclass doesn't need to override this method. Instead, it should override the specific internal validation methods.
     */
    function validateUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external virtual override returns (uint256 validationData) {
        _requireFromEntryPoint();
        validationData = _validateSignature(userOp, userOpHash);
        _validateNonce(userOp.nonce);
        _payPrefund(missingAccountFunds);
        _approvePaymasterToken(userOp);
    }

    /**
     * validate the signature is valid for this message.
     * @param userOp validate the userOp.signature field
     * @param userOpHash convenient field: the hash of the request, to check the signature against
     *          (also hashes the entrypoint and chain id)
     * @return validationData signature and time-range of this operation
     *      <20-byte> sigAuthorizer - 0 for valid signature, 1 to mark signature failure,
     *         otherwise, an address of an "authorizer" contract.
     *      <6-byte> validUntil - last timestamp this operation is valid. 0 for "indefinite"
     *      <6-byte> validAfter - first timestamp this operation is valid
     *      If the account doesn't use time-range, it is enough to return SIG_VALIDATION_FAILED value (1) for signature failure.
     *      Note that the validation code cannot use block.timestamp (or block.number) directly.
     */
    function _validateSignature(
        UserOperation calldata userOp,
        bytes32 userOpHash
    ) internal override returns (uint256 validationData) {
        if (userOp.callData.length < 4 || userOp.signature.length < 22) {
            return 1;
        }
        bytes4 methodId = bytes4(userOp.callData[0:4]);
        bytes32 ethHash = ECDSA.toEthSignedMessageHash(userOpHash);

        address signer;
        bool valid;
        (valid, signer, ) = checkValidSodiumSignature(
            ethHash,
            userOp.signature
        );

        if (!valid) {
            return 1;
        }

        if (methodId == this.executeWithSodiumAuthRecover.selector) {
            address sessionKey;
            bytes memory addressBytes = userOp.callData[16:36];
            assembly {
                sessionKey := mload(add(addressBytes, 20))
            }
            return sessionKey == signer ? 0 : 1;
        }

        if (methodId == this.executeWithSodiumAuthSession.selector) {
            address sessionKey;
            bytes memory addressBytes = userOp.callData[16:36];
            assembly {
                sessionKey := mload(add(addressBytes, 20))
            }

            bool isSafe = _safeSession.owner == address(0);
            IUserOperationValidator validator = internalReadUserOperationValidator();
            if (!isSafe) {
                // Use the on-chain security center to verify that the operation is secure.
                // Allow session access if safe
                isSafe = validator.validateUserOp(userOp) < 2;
            }
            return sessionKey == signer && isSafe ? 0 : 1;
        }

        if (methodId == this.executeWithModule.selector) {
            address module;
            bytes memory addressBytes = userOp.callData[16:36];
            assembly {
                module := mload(add(addressBytes, 20))
            }

            // if no enabled modules
            if (!isModuleEnabled(module)) {
                return 1;
            }

            return IModule(module).validateSignature(userOp, userOpHash);
        }

        if (methodId == this.execute.selector) {
            (bool existing, bool isSafe) = isSessionOwner(signer);
            IUserOperationValidator validator = internalReadUserOperationValidator();
            if (!isSafe) {
                // Use the on-chain security center to verify that the operation is secure.
                // Allow session access if safe
                isSafe = validator.validateUserOp(userOp) < 2;
            }
            return existing && isSafe ? 0 : 1;
        }

        revert("invalid methodId");
    }

    /**
     * @notice Allow eip-4337 entryPoint or wallet self to execute an action
     * @dev Relayers must ensure that the gasLimit specified for each transaction
     *      is acceptable to them. A user could specify large enough that it could
     *      consume all the gas available.
     * @param _txs Transactions to process
     */
    function execute(Transaction[] memory _txs) external {
        // only allow eip-4337 entryPoint or wallet self to execute an action
        _requireFromEntryPoint();
        // Execute the transactions
        _execute(_txs);
    }

    function executeWithSodiumAuthRecover(
        Recover calldata _recover,
        bytes calldata _authProof,
        Transaction[] calldata _txs
    ) external {
        // only allow eip-4337 entryPoint or wallet self to execute an action
        _requireFromEntryPoint();

        // Validate the sodium auth proof
        validateRecoverProof(_recover, _authProof);

        // Setup the safe session
        internalAddSafeSession(_recover.safeSessionKey);

        // Execute the transactions
        _execute(_txs);
    }

    // Support for calling modules from an account so that the module can use the account to pay gas
    function executeWithModule(
        address _module,
        uint256 _value,
        bytes memory _data
    ) external {
        // only allow eip-4337 entryPoint or wallet self to execute an action
        _requireFromEntryPoint();
        bool success;
        bytes memory result;
        (success, result) = _module.call{value: _value, gas: gasleft()}(_data);
        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function executeWithSodiumAuthSession(
        AddSession calldata _addSession,
        bytes calldata _authProof,
        Transaction[] calldata _txs
    ) external {
        // only allow eip-4337 entryPoint or wallet self to execute an action
        _requireFromEntryPoint();

        // Validate the sodium auth proof
        validateAddSessionProof(_addSession, _authProof);

        Session memory session = Session({
            owner: _addSession.sessionKey,
            uniqueId: _addSession.sessionUniqueId,
            expires: _addSession.sessionExpires
        });

        // Setup the session
        internalAddOrUpdateSession(session);

        // Execute the transactions
        _execute(_txs);
    }

    /**
     * @notice Executes a list of transactions
     * @param _txs  Transactions to execute
     */
    function _execute(Transaction[] memory _txs) private {
        // Execute transaction
        for (uint256 i = 0; i < _txs.length; i++) {
            Transaction memory transaction = _txs[i];
            bool success;
            bytes memory result;
            require(
                gasleft() >= transaction.gasLimit,
                "Sodium: NOT_ENOUGH_GAS"
            );
            if (transaction.op == Enum.Operation.DelegateCall) {
                (success, result) = transaction.target.delegatecall{
                    gas: transaction.gasLimit == 0
                        ? gasleft()
                        : transaction.gasLimit
                }(transaction.data);
            } else {
                (success, result) = transaction.target.call{
                    value: transaction.value,
                    gas: transaction.gasLimit == 0
                        ? gasleft()
                        : transaction.gasLimit
                }(transaction.data);
            }
            if (!success && transaction.revertOnError) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
    }

    /// @dev Returns the chain id used by this contract.
    function getChainId() public view returns (uint256) {
        uint256 id;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            id := chainid()
        }
        return id;
    }

    function domainSeparator() public view returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_SEPARATOR_TYPEHASH, getChainId(), this)
            );
    }

    function checkValidSodiumSignature(
        bytes32 _hash,
        bytes calldata _signature
    ) public view returns (bool valid, address signer, address trustee) {
        bytes1 sigType = bytes1(_signature[:1]);
        // {0x01}{signer}{signature}
        if (sigType == 0x01) {
            bytes memory addressBytes = _signature[1:21];
            bytes memory signatureBytes = _signature[21:];
            assembly {
                signer := mload(add(addressBytes, 20))
            }
            valid = SignatureChecker.isValidSignatureNow(
                signer,
                _hash,
                signatureBytes
            );
        // {0x02}{trustee}{signer}{delegateExpires}{signature}{delegateproof}
        } else if (sigType == 0x02) {
            uint64 delegateExpires;
            bytes memory signature;
            bytes memory delegateproof;
            (trustee, signer, delegateExpires, signature, delegateproof) = abi
                .decode(
                    _signature[1:],
                    (address, address, uint64, bytes, bytes)
                );
            if (delegateExpires < block.timestamp) {
                valid = false;
                return (valid, signer, trustee);
            }
            bytes32 dataHash = _hashTypedData(
                keccak256(
                    abi.encode(
                        _DELEGATE_AURH_TYPEHASH,
                        trustee,
                        delegateExpires
                    )
                )
            );
            bool delegateValid = SignatureChecker.isValidSignatureNow(
                signer,
                dataHash,
                delegateproof
            );
            bool trusteeValid = SignatureChecker.isValidSignatureNow(
                trustee,
                _hash,
                signature
            );
            valid = delegateValid && trusteeValid;
        } else {
            valid = false;
        }
    }
}
