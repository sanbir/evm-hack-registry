// SPDX-License-Identifier: MIT
// File: @openzeppelin/contracts/security/ReentrancyGuard.sol


// OpenZeppelin Contracts (last updated v4.9.0) (security/ReentrancyGuard.sol)

pragma solidity ^0.8.0;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be _NOT_ENTERED
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == _ENTERED;
    }
}

// File: @openzeppelin/contracts/utils/Context.sol


// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

pragma solidity ^0.8.20;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

// File: @openzeppelin/contracts/access/Ownable.sol


// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

pragma solidity ^0.8.20;


/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * The initial owner is set to the address provided by the deployer. This can
 * later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

// File: @openzeppelin/contracts/token/ERC20/IERC20.sol


// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.20;

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// File: @openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol


// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/extensions/IERC20Metadata.sol)

pragma solidity ^0.8.20;


/**
 * @dev Interface for the optional metadata functions from the ERC-20 standard.
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

// File: @openzeppelin/contracts/interfaces/IERC20.sol


// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC20.sol)

pragma solidity ^0.8.20;


// File: @openzeppelin/contracts/utils/introspection/IERC165.sol


// OpenZeppelin Contracts (last updated v5.1.0) (utils/introspection/IERC165.sol)

pragma solidity ^0.8.20;

/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// File: @openzeppelin/contracts/interfaces/IERC165.sol


// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC165.sol)

pragma solidity ^0.8.20;


// File: @openzeppelin/contracts/interfaces/IERC1363.sol


// OpenZeppelin Contracts (last updated v5.1.0) (interfaces/IERC1363.sol)

pragma solidity ^0.8.20;



/**
 * @title IERC1363
 * @dev Interface of the ERC-1363 standard as defined in the https://eips.ethereum.org/EIPS/eip-1363[ERC-1363].
 *
 * Defines an extension interface for ERC-20 tokens that supports executing code on a recipient contract
 * after `transfer` or `transferFrom`, or code on a spender contract after `approve`, in a single transaction.
 */
interface IERC1363 is IERC20, IERC165 {
    /*
     * Note: the ERC-165 identifier for this interface is 0xb0202a11.
     * 0xb0202a11 ===
     *   bytes4(keccak256('transferAndCall(address,uint256)')) ^
     *   bytes4(keccak256('transferAndCall(address,uint256,bytes)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256,bytes)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256,bytes)'))
     */

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @param data Additional data with no specified format, sent in call to `spender`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value, bytes calldata data) external returns (bool);
}

// File: @openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol


// OpenZeppelin Contracts (last updated v5.3.0) (token/ERC20/utils/SafeERC20.sol)

pragma solidity ^0.8.20;



/**
 * @title SafeERC20
 * @dev Wrappers around ERC-20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    /**
     * @dev An operation with an ERC-20 token failed.
     */
    error SafeERC20FailedOperation(address token);

    /**
     * @dev Indicates a failed `decreaseAllowance` request.
     */
    error SafeERC20FailedDecreaseAllowance(address spender, uint256 currentAllowance, uint256 requestedDecrease);

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transfer, (to, value)));
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    /**
     * @dev Variant of {safeTransfer} that returns a bool instead of reverting if the operation is not successful.
     */
    function trySafeTransfer(IERC20 token, address to, uint256 value) internal returns (bool) {
        return _callOptionalReturnBool(token, abi.encodeCall(token.transfer, (to, value)));
    }

    /**
     * @dev Variant of {safeTransferFrom} that returns a bool instead of reverting if the operation is not successful.
     */
    function trySafeTransferFrom(IERC20 token, address from, address to, uint256 value) internal returns (bool) {
        return _callOptionalReturnBool(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        forceApprove(token, spender, oldAllowance + value);
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `requestedDecrease`. If `token` returns no
     * value, non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 requestedDecrease) internal {
        unchecked {
            uint256 currentAllowance = token.allowance(address(this), spender);
            if (currentAllowance < requestedDecrease) {
                revert SafeERC20FailedDecreaseAllowance(spender, currentAllowance, requestedDecrease);
            }
            forceApprove(token, spender, currentAllowance - requestedDecrease);
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Meant to be used with tokens that require the approval
     * to be set to zero before setting it to a non-zero value, such as USDT.
     *
     * NOTE: If the token implements ERC-7674, this function will not modify any temporary allowance. This function
     * only sets the "standard" allowance. Any temporary allowance will remain active, in addition to the value being
     * set here.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeCall(token.approve, (spender, value));

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeCall(token.approve, (spender, 0)));
            _callOptionalReturn(token, approvalCall);
        }
    }

    /**
     * @dev Performs an {ERC1363} transferAndCall, with a fallback to the simple {ERC20} transfer if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            safeTransfer(token, to, value);
        } else if (!token.transferAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} transferFromAndCall, with a fallback to the simple {ERC20} transferFrom if the target
     * has no code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferFromAndCallRelaxed(
        IERC1363 token,
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        if (to.code.length == 0) {
            safeTransferFrom(token, from, to, value);
        } else if (!token.transferFromAndCall(from, to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} approveAndCall, with a fallback to the simple {ERC20} approve if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * NOTE: When the recipient address (`to`) has no code (i.e. is an EOA), this function behaves as {forceApprove}.
     * Opposedly, when the recipient address (`to`) has code, this function only attempts to call {ERC1363-approveAndCall}
     * once without retrying, and relies on the returned value to be true.
     *
     * Reverts if the returned value is other than `true`.
     */
    function approveAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            forceApprove(token, to, value);
        } else if (!token.approveAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturnBool} that reverts if call fails to meet the requirements.
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            let success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            // bubble errors
            if iszero(success) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            returnSize := returndatasize()
            returnValue := mload(0)
        }

        if (returnSize == 0 ? address(token).code.length == 0 : returnValue != 1) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturn} that silently catches all reverts and returns a bool instead.
     */
    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            returnSize := returndatasize()
            returnValue := mload(0)
        }
        return success && (returnSize == 0 ? address(token).code.length > 0 : returnValue == 1);
    }
}

// File: contracts/Revamp.sol


pragma solidity ^0.8.17;

/*─────────────────────────────────────────────
│                EXTERNAL LIBRARIES
└─────────────────────────────────────────────*/






/**
 * @title Revamp
 * @notice Decentralized protocol for token listing, revamp (burn), referral rewards, and native value redistribution.
 *         Designed to operate trustlessly, support DAO-style evolution, and integrate with external shareholding protocols.
 */
contract Revamp is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ────────────────────────────────────────
    //   CONSTANTS
    // ────────────────────────────────────────
    uint256 public constant PRECISION = 1e18;

    // ────────────────────────────────────────
    //   STRUCTS
    // ────────────────────────────────────────
    struct UserInfo {
        uint256 totalContributed;    // Native sent by user
        uint256 rewardDebt;          // Used for claim calculations
        uint256 claimedSoFar;        // Total claimed rewards
    }

    struct TokenInfo {
        uint256 rate;                // Fixed revamp rate (token per native)
        address lister;              // Who listed this token
        string logoUrl;
        uint8 decimals;
        string name;
        string symbol;
    }

    struct TokenData {
        address token;
        uint256 rate;
        address lister;
        string logoUrl;
        uint8 decimals;
        string name;
        string symbol;
    }

    // ────────────────────────────────────────
    //   STATE VARIABLES
    // ────────────────────────────────────────
    // Referral
    mapping(address => address) public referrerOf;
    address public genesisAddress;
    uint256 public referralFeePercent;       // 100 = 1%

    // Listed tokens
    mapping(address => TokenInfo) public tokenInfos;
    address[] private listedTokens;

    // Fees
    uint256 public listingFee;
    uint256 public claimFee;
    uint256 public delistFee;
    address public feeRecipient;
    uint256 public totalListingFees;

    // Revenue Splits
    uint256 public nativeFeePercent;
    address public nativeFeeRecipient;
    uint256 public shareholdingFeePercent;
    address public shareholdingFeeRecipient;

    // Global reward/accounting
    uint256 public totalNativeContributed;
    uint256 public accRewardPerShare;

    mapping(address => UserInfo) public users;
    address[] public topParticipants;

    // Revamp token ("burn" target)
    IERC20 public revampToken;
    address public tokenCollector; // Blackhole (or collector) address

    // ────────────────────────────────────────
    //   EVENTS
    // ────────────────────────────────────────
    event AssetListed(address indexed token, uint256 rate, string logoUrl, uint8 decimals, string name, string symbol, uint256 feePaid);
    event TokenDelisted(address indexed token, address indexed caller, uint256 feePaid);
    event Revamped(address indexed user, address indexed token, uint256 tokenAmount, uint256 nativeAmount);
    event WithdrawDone(address indexed user, uint256 withdrawnAmount);
    event Claimed(address indexed user, uint256 amount);
    event Reinvested(address indexed user, uint256 amount);
    event TokenMetadataUpdated(address indexed token, string newLogoUrl, uint256 newRate);
    event ListingFeeUpdated(uint256 newFee);
    event DelistFeeUpdated(uint256 newFee);
    event ClaimFeeUpdated(uint256 newFee);
    event NativeFeeUpdated(uint256 newNativeFeePercent, address newNativeFeeRecipient);
    event ShareholdingFeeUpdated(uint256 newShareholdingFeePercent, address newShareholdingFeeRecipient);
    event RevampTokensLocked(address indexed user, uint256 amount);
    event TokenCollectorUpdated(address indexed newCollector);
    event ReferralRegistered(address indexed user, address indexed referrer);
    event ReferralRewardPaid(address indexed user, address indexed referrer, uint256 amount);
    event ReferralFeeUpdated(uint256 newFeePercent);
    event GenesisAddressUpdated(address newGenesis);

    /*─────────────────────────────────────────────
    │                CONSTRUCTOR
    └─────────────────────────────────────────────*/
    constructor(
        uint256 _listingFee,
        address _feeRecipient,
        uint256 _claimFee,
        uint256 _nativeFeePercent,
        address _nativeFeeRecipient,
        uint256 _shareholdingFeePercent,
        address _shareholdingFeeRecipient,
        address _revampToken,
        uint256 _delistFee,
        uint256 _referralFeePercent,
        address _genesisAddress
    ) Ownable(msg.sender) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_nativeFeeRecipient != address(0), "Invalid native fee recipient");
        require(_shareholdingFeeRecipient != address(0), "Invalid shareholding fee recipient");
        require(_revampToken != address(0), "Invalid revamp token");
        require(_genesisAddress != address(0), "Invalid genesis");
        listingFee = _listingFee;
        delistFee = _delistFee;
        feeRecipient = _feeRecipient;
        claimFee = _claimFee;
        nativeFeePercent = _nativeFeePercent;
        nativeFeeRecipient = _nativeFeeRecipient;
        shareholdingFeePercent = _shareholdingFeePercent;
        shareholdingFeeRecipient = _shareholdingFeeRecipient;
        revampToken = IERC20(_revampToken);
        referralFeePercent = _referralFeePercent;
        genesisAddress = _genesisAddress;
    }

    /*─────────────────────────────────────────────
    │           REFERRAL MANAGEMENT
    └─────────────────────────────────────────────*/
    function updateReferralFeePercent(uint256 newFeePercent) external onlyOwner {
        require(newFeePercent <= 10000, "Too high");
        referralFeePercent = newFeePercent;
        emit ReferralFeeUpdated(newFeePercent);
    }

    function updateGenesisAddress(address newGenesis) external onlyOwner {
        require(newGenesis != address(0), "Zero genesis");
        genesisAddress = newGenesis;
        emit GenesisAddressUpdated(newGenesis);
    }

    /*─────────────────────────────────────────────
    │                LISTING LOGIC
    └─────────────────────────────────────────────*/
    function listNewAsset(
        address token,
        uint256 rate,
        string calldata logoUrl
    ) external payable nonReentrant {
        require(msg.value >= listingFee, "Fee too low");
        require(rate > 0, "Rate > 0");
        require(token != address(0), "Bad token");
        require(tokenInfos[token].lister == address(0), "Already listed");

        IERC20Metadata erc = IERC20Metadata(token);
        uint8 _decimals = erc.decimals();
        string memory _name = erc.name();
        string memory _symbol = erc.symbol();

        tokenInfos[token] = TokenInfo({
            rate: rate,
            lister: msg.sender,
            logoUrl: logoUrl,
            decimals: _decimals,
            name: _name,
            symbol: _symbol
        });
        listedTokens.push(token);

        totalListingFees += msg.value;
        (bool success, ) = feeRecipient.call{value: msg.value}("");
        require(success, "Fee transfer fail");

        emit AssetListed(token, rate, logoUrl, _decimals, _name, _symbol, msg.value);
    }

    function delistAsset(address token) external payable nonReentrant {
        TokenInfo storage info = tokenInfos[token];
        require(info.lister != address(0), "Asset not listed");
        require(msg.value >= delistFee, "Insufficient delist fee");

        totalListingFees += msg.value;
        (bool success, ) = feeRecipient.call{value: msg.value}("");
        require(success, "Fee transfer fail");

        delete tokenInfos[token];
        for (uint256 i = 0; i < listedTokens.length; i++) {
            if (listedTokens[i] == token) {
                listedTokens[i] = listedTokens[listedTokens.length - 1];
                listedTokens.pop();
                break;
            }
        }

        emit TokenDelisted(token, msg.sender, msg.value);
    }

    /*─────────────────────────────────────────────
    │     REVAMP / REFERRAL / REWARD LOGIC
    └─────────────────────────────────────────────*/
    function revamp(address token, uint256 tokenAmount, address referral) external payable nonReentrant {
        TokenInfo storage info = tokenInfos[token];
        require(info.lister != address(0), "Asset not listed");
        require(tokenAmount > 0, "Tokens > 0");
        require(msg.value > 0, "Native > 0");
        require(info.decimals > 0 && info.decimals <= 77, "Bad decimals");

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Set referral if first time
        if (referrerOf[msg.sender] == address(0)) {
            address actualRef = (referral != address(0) && referral != msg.sender)
                ? referral
                : genesisAddress;
            referrerOf[msg.sender] = actualRef;
            emit ReferralRegistered(msg.sender, actualRef);
        }
        address ref = referrerOf[msg.sender];

        // Fee calculations and allocations
        uint256 nativeFee = (msg.value * nativeFeePercent) / 10000;
        uint256 shareFee = (msg.value * shareholdingFeePercent) / 10000;
        uint256 referralFee = (msg.value * referralFeePercent) / 10000;
        uint256 netValue = msg.value - nativeFee - shareFee - referralFee;

        if (totalNativeContributed > 0) {
            accRewardPerShare += (netValue * PRECISION) / totalNativeContributed;
        }

        UserInfo storage user = users[msg.sender];
        user.totalContributed += netValue;
        totalNativeContributed += netValue;
        user.rewardDebt = (user.totalContributed * accRewardPerShare) / PRECISION;

        _updateTopParticipants(msg.sender);

        if (nativeFee > 0) {
            (bool successNative, ) = nativeFeeRecipient.call{value: nativeFee}("");
            require(successNative, "Native fee fail");
        }
        if (shareFee > 0) {
            (bool successShare, ) = shareholdingFeeRecipient.call{value: shareFee}("");
            require(successShare, "Share fee fail");
        }
        if (referralFee > 0 && ref != address(0)) {
            (bool successRef, ) = payable(ref).call{value: referralFee}("");
            require(successRef, "Referral pay fail");
            emit ReferralRewardPaid(msg.sender, ref, referralFee);
        }

        emit Revamped(msg.sender, token, tokenAmount, netValue);
    }

    function withdraw(uint256 amount) public nonReentrant {
        require(amount > 0, "Amt > 0");
        UserInfo storage user = users[msg.sender];
        require(user.totalContributed > 0, "No principal");
        uint256 pending = pendingReward(msg.sender);

        uint256 fromReward;
        uint256 fromPrincipal = 0;
        if (pending >= amount) {
            fromReward = amount;
        } else {
            fromReward = pending;
            fromPrincipal = amount - pending;
        }
        require(fromPrincipal <= user.totalContributed, "Exceeds bal");

        uint256 feePart = 0;
        if (fromReward > 0) {
            require(fromReward > claimFee, "Claim fee high");
            feePart = claimFee;
        }
        uint256 toUser = (fromReward - feePart) + fromPrincipal;
        user.claimedSoFar += fromReward;
        if (fromPrincipal > 0) {
            user.totalContributed -= fromPrincipal;
            totalNativeContributed -= fromPrincipal;
        }
        user.rewardDebt = (user.totalContributed * accRewardPerShare) / PRECISION;
        if (feePart > 0) {
            (bool feeOk, ) = feeRecipient.call{value: feePart}("");
            require(feeOk, "Fee tx fail");
        }
        (bool ok, ) = payable(msg.sender).call{value: toUser}("");
        require(ok, "Withdraw tx fail");

        emit WithdrawDone(msg.sender, amount);
    }

    function claim() external {
        uint256 pending = pendingReward(msg.sender);
        require(pending > 0, "No pending");
        withdraw(pending);
        emit Claimed(msg.sender, pending);
    }

    function reinvest() external nonReentrant {
        uint256 pending = pendingReward(msg.sender);
        require(pending > 0, "No pending");
        UserInfo storage user = users[msg.sender];
        user.claimedSoFar += pending;
        user.totalContributed += pending;
        totalNativeContributed += pending;
        user.rewardDebt = (user.totalContributed * accRewardPerShare) / PRECISION;
        emit Reinvested(msg.sender, pending);
    }

    function pendingReward(address userAddr) public view returns (uint256) {
        UserInfo storage user = users[userAddr];
        uint256 accumulated = (user.totalContributed * accRewardPerShare) / PRECISION;
        uint256 rawPending = accumulated > user.rewardDebt ? accumulated - user.rewardDebt : 0;
        uint256 maxReward = user.totalContributed * 2;
        uint256 used = user.claimedSoFar;
        if (used >= maxReward) return 0;
        uint256 leftover = maxReward - used;
        return rawPending > leftover ? leftover : rawPending;
    }

    /*─────────────────────────────────────────────
    │         TOP PARTICIPANT TRACKING
    └─────────────────────────────────────────────*/
    function _updateTopParticipants(address userAddr) internal {
        bool exists = false;
        uint256 len = topParticipants.length;
        for (uint256 i = 0; i < len; i++) {
            if (topParticipants[i] == userAddr) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            topParticipants.push(userAddr);
        }
        // Bubble sort: descending order
        for (uint256 i = 0; i < topParticipants.length; i++) {
            for (uint256 j = i + 1; j < topParticipants.length; j++) {
                if (users[topParticipants[j]].totalContributed > users[topParticipants[i]].totalContributed) {
                    address temp = topParticipants[i];
                    topParticipants[i] = topParticipants[j];
                    topParticipants[j] = temp;
                }
            }
        }
        if (topParticipants.length > 20) {
            topParticipants.pop();
        }
    }

    function getTopParticipants() external view returns (address[] memory addrs, uint256[] memory amounts) {
        uint256 len = topParticipants.length;
        addrs = new address[](len);
        amounts = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            addrs[i] = topParticipants[i];
            amounts[i] = users[topParticipants[i]].totalContributed;
        }
    }

    /*─────────────────────────────────────────────
    │           VIEW / DATA HELPERS
    └─────────────────────────────────────────────*/
    function getAllListedTokens() external view returns (TokenData[] memory) {
        uint256 len = listedTokens.length;
        TokenData[] memory arr = new TokenData[](len);
        for (uint256 i = 0; i < len; i++) {
            address t = listedTokens[i];
            TokenInfo storage info = tokenInfos[t];
            arr[i] = TokenData({
                token: t,
                rate: info.rate,
                lister: info.lister,
                logoUrl: info.logoUrl,
                decimals: info.decimals,
                name: info.name,
                symbol: info.symbol
            });
        }
        return arr;
    }

    /*─────────────────────────────────────────────
    │     ADMIN FUNCTIONS (FEES/CONFIG/ETC)
    └─────────────────────────────────────────────*/
    function updateListingFee(uint256 newFee) external onlyOwner {
        listingFee = newFee;
        emit ListingFeeUpdated(newFee);
    }
    function updateDelistFee(uint256 newFee) external onlyOwner {
        delistFee = newFee;
        emit DelistFeeUpdated(newFee);
    }
    function updateClaimFee(uint256 newFee) external onlyOwner {
        claimFee = newFee;
        emit ClaimFeeUpdated(newFee);
    }
    function updateNativeFee(uint256 newNativeFeePercent, address newRecipient) external onlyOwner {
        nativeFeePercent = newNativeFeePercent;
        nativeFeeRecipient = newRecipient;
        emit NativeFeeUpdated(newNativeFeePercent, newRecipient);
    }
    function updateShareholdingFee(uint256 newShareholdingFeePercent, address newRecipient) external onlyOwner {
        shareholdingFeePercent = newShareholdingFeePercent;
        shareholdingFeeRecipient = newRecipient;
        emit ShareholdingFeeUpdated(newShareholdingFeePercent, newRecipient);
    }
    function exportVitalData() external view onlyOwner returns (
        uint256 _totalNativeContributed,
        uint256 _accRewardPerShare,
        uint256 _totalListingFees
    ) {
        _totalNativeContributed = totalNativeContributed;
        _accRewardPerShare = accRewardPerShare;
        _totalListingFees = totalListingFees;
    }
    function updateMyTokenMetadata(address token, string calldata newLogoUrl, uint256 newRate) external nonReentrant {
        TokenInfo storage info = tokenInfos[token];
        require(info.lister != address(0), "Asset not listed");
        require(info.lister == msg.sender, "Not lister");
        info.logoUrl = newLogoUrl;
        info.rate = newRate;
        emit TokenMetadataUpdated(token, newLogoUrl, newRate);
    }
    // Revamp token collector/lock
    function updateTokenCollector(address newCollector) external onlyOwner {
        require(newCollector != address(0), "Invalid collector");
        tokenCollector = newCollector;
        emit TokenCollectorUpdated(newCollector);
    }
    function lockRevampTokens(uint256 amount) external nonReentrant {
        require(amount > 0, "Amt > 0");
        require(tokenCollector != address(0), "No collector set");
        revampToken.safeTransferFrom(msg.sender, tokenCollector, amount);
        emit RevampTokensLocked(msg.sender, amount);
    }

    /*─────────────────────────────────────────────
    │         RECEIVE NATIVE FALLBACK
    └─────────────────────────────────────────────*/
    receive() external payable {}

    /*─────────────────────────────────────────────
    │      OWNER RENOUNCE: IMMUTABLE MODE
    └─────────────────────────────────────────────*/
    function renounceTrustless() external onlyOwner {
        renounceOwnership();
        // This makes contract “trustless trust” (immutable): all owner-only functions disabled.
    }
}