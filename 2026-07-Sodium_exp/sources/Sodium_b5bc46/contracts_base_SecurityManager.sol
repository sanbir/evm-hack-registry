// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import "../chain/ISodiumAuth.sol";
import "../common/SelfAuthorized.sol";
import "../securityengine/IUserOperationValidator.sol";

///
contract SecurityManager is SelfAuthorized {
    // NETWORK_AUTH_KEY = keccak256("org.sodium.base.security.network.auth");
    bytes32 private constant NETWORK_AUTH_KEY =
        bytes32(
            0xe5230392f47deb1a37e1df3b9ee1d04b8a457138ebb1a61edeb61872e6c42322
        );

    // Here we do not restrict the chainId, this is to allow users to authenticate only once for all chains
    // keccak256(
    //     "EIP712Domain(address verifyingContract)"
    // );
    bytes32 private constant SECURITY_DOMAIN_SEPARATOR_TYPEHASH =
        0x035aff83d86937d35b32e04f0ddc6ff469290eef2f1b692d8a815c89404d4749;

    // RECOVER_NONCE_KEY = keccak256("org.sodium.base.security.recover_nonce");
    bytes32 private constant RECOVER_NONCE_KEY =
        bytes32(
            0xebd64025eccab0d68ffd8dbdf22f162b40c6e98dc2bf27a2eabea8004135b99f
        );

    // ADD_SESSION_NONCE_KEY = keccak256("org.sodium.base.security.add_session_nonce");
    bytes32 private constant ADD_SESSION_NONCE_KEY =
        bytes32(
            0xab2fb4a4f5c6f5950284b1595fdee071b14bb957fc11893b02ed7ba798528306
        );

    // USER_OP_VALIDATOR_KEY = keccak256("org.sodium.base.security.user_op_validator")
    bytes32 private constant USER_OP_VALIDATOR_KEY =
        bytes32(
            0x26af6f34783f6c05ad199b86190c89039b6a27ab2bac01a0ef363037be08c64e
        );

    // session manager safe session
    // new zk root must be committed for each recovery
    struct Recover {
        address safeSessionKey;
        uint256 recoverNonce;
    }

    // session manager
    struct AddSession {
        address sessionKey;
        bytes4 sessionUniqueId;
        uint64 sessionExpires;
    }

    bytes32 public constant _RECOVER_TYPEHASH =
        keccak256("Recover(address safeSessionKey,uint256 recoverNonce)");

    bytes32 public constant _ADD_SESSION_TYPEHASH =
        keccak256(
            "AddSession(address sessionKey,bytes4 sessionUniqueId,uint64 sessionExpires)"
        );

    // security engine
    function internalWriteUserOperationValidator(address _validator) internal {
        require(_validator != address(0), "SMOP01");
        bytes32 slot = USER_OP_VALIDATOR_KEY;
        assembly {
            sstore(slot, _validator)
        }
    }

    function internalReadUserOperationValidator()
        internal
        view
        returns (IUserOperationValidator)
    {
        bytes32 slot = USER_OP_VALIDATOR_KEY;
        IUserOperationValidator _validator;
        assembly {
            _validator := sload(slot)
        }
        return _validator;
    }

    function setUserOperationValidator(
        IUserOperationValidator _validator
    ) public authorized {
        internalWriteUserOperationValidator(address(_validator));
    }

    function validateAddSessionProof(
        AddSession calldata _addSession,
        bytes calldata _authProof
    ) public view {
        require(_addSession.sessionExpires > block.timestamp, "SMAS05");
        bytes32 dataHash = keccak256(
            abi.encode(_ADD_SESSION_TYPEHASH, _addSession)
        );
        bytes32 messageHash = _hashTypedData(dataHash);
        ISodiumAuth _auth = _readSodiumNetworkAuth();
        _auth.verifyProof(messageHash, _authProof);
    }

    /// use sodium auth to recover
    function _writeRecoverNonce(uint256 _recoverNonce) private {
        bytes32 slot = RECOVER_NONCE_KEY;
        assembly {
            sstore(slot, _recoverNonce)
        }
    }

    function _readRecoverNonce() private view returns (uint256) {
        bytes32 slot = RECOVER_NONCE_KEY;
        uint256 recoverNonce;
        assembly {
            recoverNonce := sload(slot)
        }
        return recoverNonce;
    }

    function validateRecoverProof(
        Recover calldata _recover,
        bytes calldata _authProof
    ) public {
        require(_recover.recoverNonce >= _readRecoverNonce(), "SMR01");
        bytes32 dataHash = keccak256(abi.encode(_RECOVER_TYPEHASH, _recover));
        bytes32 messageHash = _hashTypedData(dataHash);
        ISodiumAuth _auth = _readSodiumNetworkAuth();
        require(_auth.verifyProof(messageHash, _authProof), "SMR03");
        _writeRecoverNonce(_recover.recoverNonce + 1);
    }

    /// ***** auth *****
    function _writeSodiumNetworkAuth(address _auth) private {
        bytes32 slot = NETWORK_AUTH_KEY;
        assembly {
            sstore(slot, _auth)
        }
    }

    function _readSodiumNetworkAuth() internal view returns (ISodiumAuth) {
        bytes32 slot = NETWORK_AUTH_KEY;
        ISodiumAuth _auth;
        assembly {
            _auth := sload(slot)
        }
        return _auth;
    }

    function internalSetSodiumNetworkAuth(ISodiumAuth _auth) internal {
        require(address(_auth) != address(0), "SM04");
        _writeSodiumNetworkAuth(address(_auth));
    }

    function setSodiumNetworkAuth(ISodiumAuth _auth) public authorized {
        internalSetSodiumNetworkAuth(_auth);
    }

    /// EIP712
    function _getDomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(SECURITY_DOMAIN_SEPARATOR_TYPEHASH, address(this)));
    }

    /// @notice Creates an EIP-712 typed data hash
    function _hashTypedData(bytes32 dataHash) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19\x01", _getDomainSeparator(), dataHash)
            );
    }
}
