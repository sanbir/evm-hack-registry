// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ECDSAUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Stablecoin} from "./Stablecoin.sol";
import {IERC3009} from "./interfaces/IERC3009.sol";

/**
 * @title StablecoinV2
 * @notice V2 implementation that adds EIP-3009 support and frozen-funds admin controls.
 * @dev This contract inherits the legacy V1 storage layout and stores all newly added mutable state in an
 *      EIP-7201-style storage slot to avoid collisions during proxy upgrades.
 */
contract StablecoinV2 is Stablecoin, IERC3009 {
    using SafeERC20 for IERC20;

    // ==================================================
    // ===================== Structs ====================
    // ==================================================

    /// @custom:storage-location erc7201:openzeppelin.storage.StablecoinV2
    struct StablecoinV2Storage {
        mapping(address authorizer => mapping(bytes32 nonce => bool)) authorizationStates;
    }

    enum AuthorizationCancellability {
        Cancelable,
        Used,
        InvalidSignature
    }

    // ==================================================
    // ==================== Constants ===================
    // ==================================================

    // solhint-disable-next-line max-line-length
    /// @notice keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;

    // solhint-disable-next-line max-line-length
    /// @notice keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;

    /// @notice keccak256("CancelAuthorization(address authorizer,bytes32 nonce)")
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        0x158b0a9edf7a828aad02f63cd515c68ef2f50ba807396f6d12842833a1597429;

    uint8 private constant _VERSION = 2;
    // USD1 EIP-712 signature domain version.
    string private constant _EIP712_VERSION = "1";

    bytes32 private constant _STABLECOIN_V2_STORAGE_LOCATION =
        keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.StablecoinV2")) - 1)) & ~bytes32(uint256(0xff)); // solhint-disable-line max-line-length

    string private constant _AUTHORIZATION_USED_ERROR = "EIP3009: authorization is used";
    string private constant _AUTHORIZATION_NOT_YET_VALID_ERROR = "EIP3009: authorization is not yet valid";
    string private constant _AUTHORIZATION_EXPIRED_ERROR = "EIP3009: authorization is expired";
    string private constant _INVALID_SIGNATURE_ERROR = "EIP3009: invalid signature";
    string private constant _INVALID_PAYEE_ERROR = "EIP3009: caller must be the payee";
    string private constant _INVALID_BATCH_LENGTH_ERROR = "EIP3009: invalid batch length";
    string private constant _ACCOUNT_NOT_FROZEN_ERROR = "Account is not frozen";
    string private constant _INVALID_RECIPIENT_ERROR = "Invalid recipient";

    // ==================================================
    // ====================== Events ====================
    // ==================================================

    event FrozenAccountDrained(address indexed caller, address indexed account, uint256 amount);
    event FrozenFundsReallocated(address indexed caller, address indexed from, address indexed to, uint256 amount);
    event ERC20Recovered(address indexed caller, address indexed token, address indexed recipient, uint256 amount);

    // ==================================================
    // ==================== Constructor =================
    // ==================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ==================================================
    // =================== Initializers =================
    // ==================================================

    /* solhint-disable ordering */

    /// @custom:oz-upgrades-validate-as-initializer
    function initialize(
        address _initialOwner,
        string memory _name,
        string memory _symbol
    ) public virtual override {
        // There is no initializer modifier on this function, so we can call `initializeV2`
        super.initialize(_initialOwner, _name, _symbol);
        initializeV2();
    }

    /**
     * @notice Marks the proxy as initialized for the V2 upgrade step.
     * @dev Migrates EIP-712 state into the OpenZeppelin v4.9 storage layout.
     */
    /// @custom:oz-upgrades-validate-as-initializer
    function initializeV2() public reinitializer(_VERSION) {
        __EIP712_init(name(), _EIP712_VERSION);
    }

    // ==================================================
    // ==================== Functions ===================
    // ==================================================

    /// @inheritdoc IERC3009
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override notFrozen(_msgSender()) {
        _transferWithAuthorization(
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s,
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH
        );
    }

    /* solhint-enable ordering */

    /// @inheritdoc IERC3009
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override notFrozen(_msgSender()) {
        require(to == _msgSender(), _INVALID_PAYEE_ERROR);
        _transferWithAuthorization(
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s,
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH
        );
    }

    /// @inheritdoc IERC3009
    function cancelAuthorization(
        address authorizer,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override notFrozen(_msgSender()) {
        _requireAuthorizationCanBeCanceled(_getAuthorizationCancellability(authorizer, nonce, v, r, s));

        _setAuthorizationAsUsed(authorizer, nonce);
        emit AuthorizationCanceled(authorizer, nonce);
    }

    /**
     * @notice Attempt to cancel multiple authorizations
     * @dev When `_ignoreErrors` is true, entries that fail the preflight cancellation checks are skipped.
     * @dev A frozen caller is still rejected before any per-item processing begins.
     * @dev Malformed signatures do not bypass signature validation; they are treated as invalid entries and either
     *      return `false` or revert depending on `_ignoreErrors`.
     * @param _authorizerList Authorizer addresses
     * @param _nonceList Authorization nonces
     * @param _vList v values of the signatures
     * @param _rList r values of the signatures
     * @param _sList s values of the signatures
     * @param _ignoreErrors True to continue past entries that fail the cancellability check without reverting
     * @return _didCancelList Boolean results indicating which authorizations were canceled by this call
     */
    function batchCancelAuthorization(
        address[] calldata _authorizerList,
        bytes32[] calldata _nonceList,
        uint8[] calldata _vList,
        bytes32[] calldata _rList,
        bytes32[] calldata _sList,
        bool _ignoreErrors
    )
        external
        notFrozen(_msgSender())
        returns (bool[] memory _didCancelList)
    {
        uint256 authorizationCount = _authorizerList.length;
        require(
            authorizationCount == _nonceList.length &&
                authorizationCount == _vList.length &&
                authorizationCount == _rList.length &&
                authorizationCount == _sList.length,
            _INVALID_BATCH_LENGTH_ERROR
        );

        _didCancelList = new bool[](authorizationCount);

        for (uint256 i; i < authorizationCount; ++i) {
            _didCancelList[i] = _processBatchCancellation(
                _authorizerList[i],
                _nonceList[i],
                _vList[i],
                _rList[i],
                _sList[i],
                _ignoreErrors
            );
        }
    }

    /**
     * @notice Moves the full token balance of a frozen account into owner custody.
     * @dev This function requires the source account to already be frozen.
     * @dev This function still respects the paused state and will revert while paused.
     * @dev The transfer bypasses the source-account frozen check only so funds can be recovered from the frozen
     *      account, but the destination must still satisfy the normal recipient freeze policy.
     * @param _account The frozen account to drain.
     */
    function drain(address _account) external onlyOwner {
        require(frozen[_account], _ACCOUNT_NOT_FROZEN_ERROR);

        uint256 amount = balanceOf(_account);
        _transferFromFrozenSource(_account, owner(), amount);

        emit FrozenAccountDrained(_msgSender(), _account, amount);
    }

    /**
     * @notice Recovers ERC-20 balances held by the token contract.
     * @dev This function still respects the paused state and will revert while paused.
     * @dev If `_token` is this token, recovery uses the contract's normal transfer path and therefore still applies
     *      the standard frozen-account checks to the recipient.
     * @param _token The token address to recover.
     * @param _recipient The recipient of the recovered tokens.
     * @param _amount The amount to recover, in the token's base units.
     */
    function recoverERC20(
        address _token,
        address _recipient,
        uint256 _amount
    ) external onlyOwner notFrozen(_recipient) {
        require(_recipient != address(0), _INVALID_RECIPIENT_ERROR);
        _requireNotPaused();

        if (_token == address(this)) {
            _transfer(address(this), _recipient, _amount);
        } else {
            IERC20(_token).safeTransfer(_recipient, _amount);
        }

        emit ERC20Recovered(_msgSender(), _token, _recipient, _amount);
    }

    /**
     * @notice Reallocates tokens from a frozen source account into a replacement account.
     * @dev This function requires `_from` to already be frozen and rejects a frozen replacement account.
     * @dev This function still respects the paused state and will revert while paused.
     * @dev The transfer bypasses the source-account frozen check only so funds can be moved out of the frozen source,
     *      but the replacement account must still satisfy the normal recipient freeze policy.
     * @param _from The frozen source account.
     * @param _to The replacement account.
     * @param _amount The amount to move, in token base units.
     */
    function reallocate(address _from, address _to, uint256 _amount) external onlyOwner {
        require(frozen[_from], _ACCOUNT_NOT_FROZEN_ERROR);

        _transferFromFrozenSource(_from, _to, _amount);
        emit FrozenFundsReallocated(_msgSender(), _from, _to, _amount);
    }

    /// @inheritdoc IERC3009
    function authorizationState(address authorizer, bytes32 nonce) external view override returns (bool) {
        return _authorizationState(authorizer, nonce);
    }

    function version() external virtual view returns (uint8) {
        return _VERSION;
    }

    // ==================================================
    // ================= Internal Functions =============
    // ==================================================

    function _transfer(
        address _from,
        address _to,
        uint256 _amount
    ) internal override {
        require(_to != address(this), _INVALID_RECIPIENT_ERROR);
        super._transfer(_from, _to, _amount);
    }

    function _setAuthorizationAsUsed(address _authorizer, bytes32 _nonce) internal {
        StablecoinV2Storage storage $ = _getStorage();
        $.authorizationStates[_authorizer][_nonce] = true;
    }

    function _processBatchCancellation(
        address _authorizer,
        bytes32 _nonce,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        bool _ignoreErrors
    ) internal returns (bool) {
        AuthorizationCancellability cancelability = _getAuthorizationCancellability(_authorizer, _nonce, _v, _r, _s);

        if (cancelability != AuthorizationCancellability.Cancelable) {
            if (!_ignoreErrors) {
                _requireAuthorizationCanBeCanceled(cancelability);
            }

            return false;
        }

        _setAuthorizationAsUsed(_authorizer, _nonce);
        emit AuthorizationCanceled(_authorizer, _nonce);
        return true;
    }

    function _transferWithAuthorization(
        address _from,
        address _to,
        uint256 _value,
        uint256 _validAfter,
        uint256 _validBefore,
        bytes32 _nonce,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        bytes32 _typehash
    ) internal {
        _requireValidAuthorization(_from, _nonce, _validAfter, _validBefore);
        _requireValidSignature(
            _from,
            keccak256(abi.encode(_typehash, _from, _to, _value, _validAfter, _validBefore, _nonce)),
            _v,
            _r,
            _s
        );

        _setAuthorizationAsUsed(_from, _nonce);
        _transfer(_from, _to, _value);
        emit AuthorizationUsed(_from, _nonce);
    }

    // Admin frozen-funds actions intentionally bypass only the source-account frozen check.
    // They still obey the global paused state and the standard destination freeze policy.
    function _transferFromFrozenSource(
        address _from,
        address _to,
        uint256 _amount
    ) internal whenNotPaused notFrozen(_to) {
        // Call the ERC20 base implementation directly so frozen-funds admin flows can move funds out of a frozen source
        // without bypassing the pause or frozen-recipient checks above.
        ERC20Upgradeable._transfer(_from, _to, _amount);
    }

    function _authorizationState(address _authorizer, bytes32 _nonce) internal view returns (bool) {
        StablecoinV2Storage storage $ = _getStorage();
        return $.authorizationStates[_authorizer][_nonce];
    }

    function _requireValidAuthorization(
        address _authorizer,
        bytes32 _nonce,
        uint256 _validAfter,
        uint256 _validBefore
    ) internal view {
        require(block.timestamp > _validAfter, _AUTHORIZATION_NOT_YET_VALID_ERROR);
        require(block.timestamp < _validBefore, _AUTHORIZATION_EXPIRED_ERROR);
        _requireUnusedAuthorization(_authorizer, _nonce);
    }

    function _requireUnusedAuthorization(address _authorizer, bytes32 _nonce) internal view {
        require(!_authorizationState(_authorizer, _nonce), _AUTHORIZATION_USED_ERROR);
    }

    function _requireValidSignature(
        address _authorizer,
        bytes32 _structHash,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) internal view {
        require(_isValidSignature(_authorizer, _structHash, _v, _r, _s), _INVALID_SIGNATURE_ERROR);
    }

    function _getAuthorizationCancellability(address _authorizer, bytes32 _nonce, uint8 _v, bytes32 _r, bytes32 _s)
        internal
        view
        returns (AuthorizationCancellability)
    {
        // Caller frozen policy is enforced at the external entrypoints. This helper only evaluates
        // per-authorization state and signature validity.
        if (_authorizationState(_authorizer, _nonce)) {
            return AuthorizationCancellability.Used;
        }
        if (!_isValidSignature(_authorizer, _getCancelAuthorizationHash(_authorizer, _nonce), _v, _r, _s)) {
            return AuthorizationCancellability.InvalidSignature;
        }

        return AuthorizationCancellability.Cancelable;
    }

    function _isValidSignature(
        address _authorizer,
        bytes32 _structHash,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) internal view returns (bool) {
        bytes32 hash = _hashTypedDataV4(_structHash);
        (address recovered, ECDSAUpgradeable.RecoverError recoverError) = ECDSAUpgradeable.tryRecover(hash, _v, _r, _s);
        return recoverError == ECDSAUpgradeable.RecoverError.NoError && recovered == _authorizer;
    }

    function _requireAuthorizationCanBeCanceled(
        AuthorizationCancellability _cancellability
    ) internal pure {
        if (_cancellability == AuthorizationCancellability.Used) {
            revert(_AUTHORIZATION_USED_ERROR);
        }
        if (_cancellability == AuthorizationCancellability.InvalidSignature) {
            revert(_INVALID_SIGNATURE_ERROR);
        }
    }

    function _getCancelAuthorizationHash(address _authorizer, bytes32 _nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, _authorizer, _nonce));
    }

    function _getStorage() private pure returns (StablecoinV2Storage storage $) {
        bytes32 location = _STABLECOIN_V2_STORAGE_LOCATION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := location
        }
    }
}
