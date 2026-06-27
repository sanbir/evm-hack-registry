// File: contracts/GetPrice.sol



pragma solidity ^0.8.9;

interface GetPrice {
  function WBNB() external view returns (address);
  function getTokenToBNBPrice(address path0) external view returns (uint256 amountOut);
}
// File: contracts/interfaces/IPoolConfiguration.sol

pragma solidity ^0.8.9;

interface IPoolConfiguration {
  function getOptimalUtilizationRate() external view returns (uint256);

  function getBaseBorrowRate() external view returns (uint256);

  function getLiquidationBonusPercent() external view returns (uint256);

  function getCollateralPercent() external view returns (uint256);

  function calculateInterestRate(uint256 _totalBorrows, uint256 _totalLiquidity)
    external
    view
    returns (uint256 borrowInterestRate);

  function getUtilizationRate(uint256 _totalBorrows, uint256 _totalLiquidity)
    external
    view
    returns (uint256 utilizationRate);
}

// File: contracts/interfaces/ILendingPool.sol

pragma solidity ^0.8.9;

interface ILendingPool {
  /**
   * Return if an account is healthy or not
   */
  function isAccountHealthy(address _account) external view returns (bool);
}

// File: @openzeppelin/contracts/security/ReentrancyGuard.sol


// OpenZeppelin Contracts v4.4.1 (security/ReentrancyGuard.sol)

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
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}

// File: @openzeppelin/contracts/utils/Address.sol


// OpenZeppelin Contracts (last updated v4.7.0) (utils/Address.sol)

pragma solidity ^0.8.1;

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
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
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
        return functionCall(target, data, "Address: low-level call failed");
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
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
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
        require(isContract(target), "Address: call to non-contract");

        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResult(success, returndata, errorMessage);
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
        require(isContract(target), "Address: static call to non-contract");

        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResult(success, returndata, errorMessage);
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
        require(isContract(target), "Address: delegate call to non-contract");

        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verifies that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason using the provided one.
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
}

// File: @openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol


// OpenZeppelin Contracts v4.4.1 (token/ERC20/extensions/draft-IERC20Permit.sol)

pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 Permit extension allowing approvals to be made via signatures, as defined in
 * https://eips.ethereum.org/EIPS/eip-2612[EIP-2612].
 *
 * Adds the {permit} method, which can be used to change an account's ERC20 allowance (see {IERC20-allowance}) by
 * presenting a message signed by the account. By not relying on {IERC20-approve}, the token holder account doesn't
 * need to send a transaction, and thus is not required to hold Ether at all.
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

// File: @openzeppelin/contracts/token/ERC20/IERC20.sol


// OpenZeppelin Contracts (last updated v4.6.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.0;

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

// File: @openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol


// OpenZeppelin Contracts (last updated v4.7.0) (token/ERC20/utils/SafeERC20.sol)

pragma solidity ^0.8.0;




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

    function safeTransfer(
        IERC20 token,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        require(
            (value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        uint256 newAllowance = token.allowance(address(this), spender) + value;
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
            uint256 newAllowance = oldAllowance - value;
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
        }
    }

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
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) {
            // Return data is optional
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}

// File: @openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol


// OpenZeppelin Contracts v4.4.1 (token/ERC20/extensions/IERC20Metadata.sol)

pragma solidity ^0.8.0;


/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
 *
 * _Available since v4.1._
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

// File: @openzeppelin/contracts/utils/Context.sol


// OpenZeppelin Contracts v4.4.1 (utils/Context.sol)

pragma solidity ^0.8.0;

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

// File: @openzeppelin/contracts/token/ERC20/ERC20.sol


// OpenZeppelin Contracts (last updated v4.7.0) (token/ERC20/ERC20.sol)

pragma solidity ^0.8.0;




/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC20
 * applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */
contract ERC20 is Context, IERC20, IERC20Metadata {
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * The default value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `amount` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `amount`.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = allowance(owner, spender);
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
        }
        _balances[to] += amount;

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
        }
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `amount`.
     *
     * Does not update the allowance amount in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Might emit an {Approval} event.
     */
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * has been transferred to `to`.
     * - when `from` is zero, `amount` tokens have been minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens have been burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}
}

// File: @openzeppelin/contracts/access/Ownable.sol


// OpenZeppelin Contracts (last updated v4.7.0) (access/Ownable.sol)

pragma solidity ^0.8.0;


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

// File: contracts/TiFiPoolShare.sol

pragma solidity ^0.8.9;





/**
 * The token to represent the share of lending liquidity
 */
contract TiFiPoolShare is ERC20, Ownable, ReentrancyGuard {
  // The lending pool of the TiFiPoolShare token
  ILendingPool private lendingPool;

  // The underlying asset for the pool
  ERC20 public underlyingAsset;

  constructor(
    string memory _name,
    string memory _symbol,
    ILendingPool _lendingPoolAddress,
    ERC20 _tokenAddress
  ) ERC20(_name, _symbol) {
    lendingPool = _lendingPoolAddress;
    underlyingAsset = _tokenAddress;
  }

  // Mint TiFiPoolShare token to the address with the amount
  function mint(address _account, uint256 _amount) external onlyOwner {
    _mint(_account, _amount);
  }

  // Burn TiFiPoolShare token from the address with the amount
  function burn(address _account, uint256 _amount) external onlyOwner {
    _burn(_account, _amount);
  }

  // Lending pool will check the account health of sender. If the sender transfer PoolShare token to the receiver and the sender account is not healthy, the transfer will be revert.
  function _transfer(
    address _from,
    address _to,
    uint256 _amount
  ) internal override {
    super._transfer(_from, _to, _amount);
    require(lendingPool.isAccountHealthy(_from), "TIFI: TRANSFER_NOT_ALLOWED");
  }
}
// File: contracts/TiFiPoolShareDeployer.sol

pragma solidity ^0.8.9;




contract TiFiPoolShareDeployer {
  // Deploy TiFiPoolShare token for the lending pool
  function createTiFiPoolShare(
    string memory _name,
    string memory _symbol,
    ERC20 _underlyingAsset
  ) public returns (TiFiPoolShare) {
    TiFiPoolShare tps = new TiFiPoolShare(
      _name,
      _symbol,
      ILendingPool(msg.sender),
      _underlyingAsset
    );
    tps.transferOwnership(msg.sender);
    return tps;
  }
}

// File: contracts/LendingPool.sol

pragma solidity ^0.8.9;










// Lending pool contract, this contract manages all states and handles user interaction with the pool.
contract LendingPool is Ownable, ILendingPool, ReentrancyGuard {
  using SafeERC20 for ERC20;

  /*
   * Lending pool smart contracts
   * -----------------------------
   * Each ERC20 token has an individual pool which users provide their liquidity to the pool.
   * Users can use their liquidity as collateral to borrow any asset from all pools if their account is still healthy.
   * By account health checking, the total borrow value must less than the total collateral value (collateral value is
   * ~75% of the liquidity value depends on each token). Borrower need to repay the loan with accumulated interest.
   * Liquidity provider would receive the borrow interest. In case of the user account is not healthy
   * then liquidator can help to liquidate the user's account then receive the collateral with liquidation bonus as the reward.
   *
   * The status of the pool
   * -----------------------------
   * The pool has 3 status. every pool will have only one status at a time.
   * 1. INACTIVE - the pool is on initialized state or inactive state so it's not ready for user to do any actions. users can't deposit, borrow,
   * repay and withdraw
   * 2 .ACTIVE - the pool is active. users can deposit, borrow, repay, withdraw and liquidate
   * 3. CLOSED - the pool is waiting for inactive state. users can clear their account by repaying, withdrawal, liquidation but can't deposit, borrow
   */
  enum PoolStatus {
    INACTIVE,
    ACTIVE,
    CLOSED
  }
  uint256 internal constant SECONDS_PER_YEAR = 365 days;

  /**
   * @dev emitted on initilize pool
   * @param pool the address of the ERC20 token of the pool
   * @param shareAddress the address of the pool's share token
   * @param poolConfigAddress the address of the pool's configuration contract
   */
  event PoolInitialized(
    address indexed pool,
    address indexed shareAddress,
    address indexed poolConfigAddress
  );

  /**
   * @dev emitted on update pool configuration
   * @param pool the address of the ERC20 token of the pool
   * @param poolConfigAddress the address of the updated pool's configuration contract
   */
  event PoolConfigUpdated(address indexed pool, address poolConfigAddress);

  /**
   * @dev emitted on pool updates interest
   * @param pool the address of the ERC20 token of the pool
   * @param cumulativeBorrowInterest the borrow interest which accumulated from last update timestamp to now
   * @param totalBorrows the updated total borrows of the pool. increasing by the cumulative borrow interest.
   */
  event PoolInterestUpdated(
    address indexed pool,
    uint256 cumulativeBorrowInterest,
    uint256 totalBorrows
  );

  /**
   * @dev emitted on deposit
   * @param pool the address of the ERC20 token of the pool
   * @param user the address of the user who deposit the ERC20 token to the pool
   * @param depositShares the share amount of the ERC20 token which calculated from deposit amount
   * Note: depositShares is the same as number of alphaToken
   * @param depositAmount the amount of the ERC20 that deposit to the pool
   */
  event Deposit(
    address indexed pool,
    address indexed user,
    uint256 depositShares,
    uint256 depositAmount
  );

  /**
   * @dev emitted on borrow
   * @param pool the address of the ERC20 token of the pool
   * @param user the address of the user who borrow the ERC20 token from the pool
   * @param borrowShares the amount of borrow shares which calculated from borrow amount
   * @param borrowAmount the amount of borrow
   */
  event Borrow(
    address indexed pool,
    address indexed user,
    uint256 borrowShares,
    uint256 borrowAmount
  );

  /**
   * @dev emitted on repay
   * @param pool the address of the ERC20 token of the pool
   * @param user the address of the user who repay the ERC20 token to the pool
   * @param repayShares the amount of repay shares which calculated from repay amount
   * @param repayAmount the amount of repay
   */
  event Repay(address indexed pool, address indexed user, uint256 repayShares, uint256 repayAmount);

  /**
   * @dev emitted on withdraw shares
   * @param pool the address of the ERC20 token of the pool
   * @param user the address of the user who withdraw the ERC20 token from the pool
   * @param withdrawShares the amount of withdraw shares which calculated from withdraw amount
   * @param withdrawAmount the amount of withdraw
   */
  event Withdraw(
    address indexed pool,
    address indexed user,
    uint256 withdrawShares,
    uint256 withdrawAmount
  );

  /**
   * @dev emitted on liquidate
   * @param user the address of the user who is liquidated by liquidator
   * @param pool the address of the ERC20 token which is liquidated by liquidator
   * @param collateral the address of the ERC20 token that liquidator received as a rewards
   * @param liquidateAmount the amount of the ERC20 token that liquidator liquidate for the user
   * @param liquidateShares the amount of liquidate shares which calculated from liquidate amount
   * @param collateralAmount the amount of the collateral which calculated from liquidate amount that liquidator want to liquidate
   * @param collateralShares the amount of collateral shares which liquidator received from liquidation in from of share token
   * @param liquidator the address of the liquidator
   */
  event Liquidate(
    address indexed user,
    address pool,
    address collateral,
    uint256 liquidateAmount,
    uint256 liquidateShares,
    uint256 collateralAmount,
    uint256 collateralShares,
    address liquidator
  );

  /**
   * @dev the struct for storing the user's state separately on each pool
   */
  struct UserPoolData {
    // the user set to used this pool as collateral for borrowing
    bool disableUseAsCollateral;
    // borrow shares of the user of this pool. If user didn't borrow this pool then shere will be 0
    uint256 borrowShares;
  }

  struct Pool {
    PoolStatus status;
    TiFiPoolShare shareToken;
    IPoolConfiguration poolConfig;
    uint256 totalBorrows;
    uint256 totalBorrowShares;
    uint256 poolReserves;
    uint256 lastUpdateTimestamp;
  }

  /**
   * @dev the mapping from the ERC20 token to the pool struct of that ERC20 token
   * token address => pool
   */
  mapping(address => Pool) public pools;

  /**
   * @dev the mapping from user address to the ERC20 token to the user data of
   * that ERC20 token's pool
   * user address => token address => user pool data
   */
  mapping(address => mapping(address => UserPoolData)) public userPoolData;

  /**
   * @dev list of all tokens on the lending pool contract.
   */
  ERC20[] public tokenList;

  // Get token price based on BNB
  GetPrice getPrice;

  TiFiPoolShareDeployer public shareDeployer;

  // Whether or not to enable whitelist for liquidators
  bool public liquidatorWhitelisted;
  mapping(address => bool) public liquidatorWhitelist;

  // Max purchase percent of each liquditation is 50% of user borrowed shares
  uint256 public constant CLOSE_FACTOR = 0.5 * 1e18;
  uint256 public constant MAX_UTILIZATION_RATE = 1 * 1e18;
  uint256 public reservePercent = 0.05 * 1e18;

  constructor(TiFiPoolShareDeployer _shareDeployer, GetPrice _getPrice) {
    shareDeployer = _shareDeployer;
    getPrice = _getPrice;
    liquidatorWhitelist[msg.sender] = true;
  }

  function setLiquidatorWhitelist(bool _isWhitelisted) external onlyOwner {
    require(_isWhitelisted != liquidatorWhitelisted, "TIFI: SAME_VALUE");
    liquidatorWhitelisted = _isWhitelisted;
  }

  function addLiquidator(address _liquidator) external onlyOwner {
    require(!liquidatorWhitelist[_liquidator], "TIFI: ALREADY_ADDED");
    liquidatorWhitelist[_liquidator] = true;
  }

  function removeLiquidator(address _liquidator) external onlyOwner {
    require(liquidatorWhitelist[_liquidator], "TIFI: ALREADY_REMOVED");
    liquidatorWhitelist[_liquidator] = false;
  }

  // Get the price of a token based on WBNB
  function getPriceWBNB(address _token) internal view returns (uint256) {
    return _token == getPrice.WBNB() ? 1e18 : getPrice.getTokenToBNBPrice(_token);
  }

  /**
   * @dev calculate the interest rate which is the part of the annual interest rate on the elapsed time
   * @param _rate an annual interest rate express in WAD
   * @param _fromTimestamp the start timestamp to calculate interest
   * @param _toTimestamp the end timestamp to calculate interest
   * @return the interest rate in between the start timestamp to the end timestamp
   */
  function calculateLinearInterest(
    uint256 _rate,
    uint256 _fromTimestamp,
    uint256 _toTimestamp
  ) internal pure returns (uint256) {
    return ((_rate * (_toTimestamp - _fromTimestamp)) / SECONDS_PER_YEAR) + 1e18;
  }

  /**
   * @dev get total available liquidity in the ERC20 token pool
   * @param _token the ERC20 token of the pool
   * @return the balance of the ERC20 token in the pool
   */
  function getTotalAvailableLiquidity(ERC20 _token) public view returns (uint256) {
    return _token.balanceOf(address(this));
  }

  /**
   * @dev get total liquidity of the ERC20 token pool
   * @param _token the ERC20 token of the pool
   * @return the total liquidity on the lending pool which is the sum of total borrows and available liquidity
   */
  function getTotalLiquidity(ERC20 _token) public view returns (uint256) {
    Pool storage pool = pools[address(_token)];
    return
      pool.totalBorrows + getTotalAvailableLiquidity(_token) - pools[address(_token)].poolReserves;
  }

  /**
   * @dev update accumulated pool's borrow interest from last update timestamp to now then add to total borrows of that pool.
   * any function that use this modifier will update pool's total borrows before starting the function.
   * @param  _token the ERC20 token of the pool that will update accumulated borrow interest to total borrows
   */
  modifier updatePoolWithInterestsAndTimestamp(ERC20 _token) {
    Pool storage pool = pools[address(_token)];
    uint256 borrowInterestRate = pool.poolConfig.calculateInterestRate(
      pool.totalBorrows,
      getTotalLiquidity(_token)
    );
    uint256 cumulativeBorrowInterest = calculateLinearInterest(
      borrowInterestRate,
      pool.lastUpdateTimestamp,
      block.timestamp
    );

    // Update pool info
    uint256 previousBorrows = pool.totalBorrows;
    pool.totalBorrows = (cumulativeBorrowInterest * previousBorrows) / 1e18;
    pool.poolReserves += ((pool.totalBorrows - previousBorrows) * reservePercent) / 1e18;
    pool.lastUpdateTimestamp = block.timestamp;
    emit PoolInterestUpdated(address(_token), cumulativeBorrowInterest, pool.totalBorrows);
    _;
  }

  /**
   * @dev initialize the ERC20 token pool. only owner can initialize the pool.
   * @param _token the ERC20 token of the pool
   * @param _poolConfig the configuration contract of the pool
   */
  function initPool(ERC20 _token, IPoolConfiguration _poolConfig) external onlyOwner {
    for (uint256 i = 0; i < tokenList.length; i++) {
      require(tokenList[i] != _token, "TIFI: POOL_EXIST");
    }
    string memory shareTokenSymbol = string(abi.encodePacked("TiFi", _token.symbol()));
    string memory shareTokenName = string(abi.encodePacked("TiFi", _token.name()));
    TiFiPoolShare shareToken = shareDeployer.createTiFiPoolShare(
      shareTokenName,
      shareTokenSymbol,
      _token
    );
    Pool memory pool = Pool(PoolStatus.INACTIVE, shareToken, _poolConfig, 0, 0, 0, block.timestamp);
    pools[address(_token)] = pool;
    tokenList.push(_token);
    emit PoolInitialized(address(_token), address(shareToken), address(_poolConfig));
  }

  /**
   * @dev update pool configuration contract of the pool. only owner can set the pool configuration.
   * @param _token the ERC20 token of the pool that will set the configuration
   * @param _poolConfig the interface of the pool's configuration contract
   */
  function updatePool(ERC20 _token, IPoolConfiguration _poolConfig) external onlyOwner {
    Pool storage pool = pools[address(_token)];
    require(address(pool.shareToken) != address(0), "TIFI: POOL_NOT_EXIST");
    pool.poolConfig = _poolConfig;
    emit PoolConfigUpdated(address(_token), address(_poolConfig));
  }

  /**
   * @dev set the status of the lending pool. only owner can set the pool's status
   * @param _token the ERC20 token of the pool
   * @param _status the status of the pool
   */
  function setPoolStatus(ERC20 _token, PoolStatus _status) external onlyOwner {
    Pool storage pool = pools[address(_token)];
    pool.status = _status;
  }

  /**
   * @dev set user uses the ERC20 token as collateral flag
   * @param _token the ERC20 token of the pool
   * @param _useAsCollateral the boolean that represent user use the ERC20 token on the pool as collateral or not
   */
  function setUserUseCollateral(ERC20 _token, bool _useAsCollateral) external {
    UserPoolData storage userData = userPoolData[msg.sender][address(_token)];
    userData.disableUseAsCollateral = !_useAsCollateral;
    // When disabling as collateral, also need to check the account health
    if (!_useAsCollateral) {
      require(isAccountHealthy(msg.sender), "TIFI: ACCOUNT_UNHEALTHY");
    }
  }

  // Set the GetPrice contract, the lending pool will use the contract to get BNB prices for each token.
  function setGetPrice(GetPrice _getPrice) external onlyOwner {
    getPrice = _getPrice;
  }

  // Get the pool of the ERC20 token
  function getPool(ERC20 _token)
    external
    view
    returns (
      PoolStatus status,
      address shareTokenAddress,
      address poolConfigAddress,
      uint256 totalBorrows,
      uint256 totalBorrowShares,
      uint256 totalLiquidity,
      uint256 totalAvailableLiquidity,
      uint256 lastUpdateTimestamp,
      uint256 borrowRate,
      uint256 lendRate
    )
  {
    Pool storage pool = pools[address(_token)];
    shareTokenAddress = address(pool.shareToken);
    poolConfigAddress = address(pool.poolConfig);
    totalBorrows = pool.totalBorrows;
    totalBorrowShares = pool.totalBorrowShares;
    totalLiquidity = getTotalLiquidity(_token);
    totalAvailableLiquidity = getTotalAvailableLiquidity(_token);
    lastUpdateTimestamp = pool.lastUpdateTimestamp;
    status = pool.status;
    borrowRate = pool.poolConfig.calculateInterestRate(totalBorrows, totalLiquidity);
    lendRate = totalLiquidity == 0 ? 0 : (borrowRate * totalBorrows) / totalLiquidity;
  }

  /**
   * @dev get user's compounded liquidity balance of the user in the ERC20 token pool
   * @param _user the account address of the user
   * @param _token the ERC20 token of the pool that will get the compounded liquidity balance
   * @return the compounded liquidity balance of the user on the ERC20 token pool
   */
  function getUserCompoundedLiquidityBalance(address _user, ERC20 _token)
    public
    view
    returns (uint256)
  {
    Pool storage pool = pools[address(_token)];
    uint256 userLiquidityShares = pool.shareToken.balanceOf(_user);
    return calculateRoundDownLiquidityAmount(_token, userLiquidityShares);
  }

  /**
   * @notice a ceiling division
   * @return the ceiling result of division
   */
  function divCeil(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b > 0, "divider must more than 0");
    uint256 c = a / b;
    if (a % b != 0) {
      c = c + 1;
    }
    return c;
  }

  /**
   * @dev get user's compounded borrow balance of the user in the ERC20 token pool
   * @param _user the address of the user
   * @param _token the ERC20 token of the pool that will get the compounded borrow balance
   * @return the compounded borrow balance of the user on the ERC20 token pool
   */
  function getUserCompoundedBorrowBalance(address _user, ERC20 _token)
    public
    view
    returns (uint256)
  {
    uint256 userBorrowShares = userPoolData[_user][address(_token)].borrowShares;
    return calculateRoundUpBorrowAmount(_token, userBorrowShares);
  }

  /**
   * @dev get user data of the ERC20 token pool
   * @param _user the address of user that need to get the data
   * @param _token the ERC20 token of the pool that need to get the data of the user
   * @return compoundedLiquidityBalance - the compounded liquidity balance of this user in this ERC20 token pool,
   * compoundedBorrowBalance - the compounded borrow balance of this user in this ERC20 pool,
   * userUsePoolAsCollateral - the boolean flag that the user
   * uses the liquidity in this ERC20 token pool as collateral or not
   */
  function getUserPoolData(address _user, ERC20 _token)
    public
    view
    returns (
      uint256 compoundedLiquidityBalance,
      uint256 compoundedBorrowBalance,
      bool userUsePoolAsCollateral
    )
  {
    compoundedLiquidityBalance = getUserCompoundedLiquidityBalance(_user, _token);
    compoundedBorrowBalance = getUserCompoundedBorrowBalance(_user, _token);
    userUsePoolAsCollateral = !userPoolData[_user][address(_token)].disableUseAsCollateral;
  }

  /**
   * @dev calculate liquidity share amount (round-down)
   * @param _token the ERC20 token of the pool
   * @param _amount the amount of liquidity to calculate the liquidity shares
   * @return the amount of liquidity shares which is calculated from the below formula
   * liquidity shares = (_amount * total liquidity shares) / total liquidity
   * if the calculated liquidity shares = 2.9 then liquidity shares will be 2
   */
  function calculateRoundDownLiquidityShareAmount(ERC20 _token, uint256 _amount)
    internal
    view
    returns (uint256)
  {
    Pool storage pool = pools[address(_token)];
    uint256 totalLiquidity = getTotalLiquidity(_token);
    uint256 totalLiquidityShares = pool.shareToken.totalSupply();
    if (totalLiquidity == 0 && totalLiquidityShares == 0) {
      return _amount;
    }
    return (_amount * totalLiquidityShares) / totalLiquidity;
  }

  /**
   * @dev calculate borrow share amount (round-up)
   * @param _token the ERC20 token of the pool
   * @param _amount the amount of borrow to calculate the borrow shares
   * @return the borrow amount which is calculated from the below formula
   * borrow shares = (amount * total borrow shares) / total borrow
   * if the calculated borrow shares = 10.1 then the borrow shares = 11
   */
  function calculateRoundUpBorrowShareAmount(ERC20 _token, uint256 _amount)
    internal
    view
    returns (uint256)
  {
    Pool storage pool = pools[address(_token)];
    // borrow share amount of the first borrowing is equal to amount
    if (pool.totalBorrows == 0 || pool.totalBorrowShares == 0) {
      return _amount;
    }
    return divCeil(_amount * pool.totalBorrowShares, pool.totalBorrows);
  }

  /**
   * @dev calculate borrow share amount (round-down)
   * @param _token the ERC20 token of the pool
   * @param _amount the amount of borrow to calculate the borrow shares
   * @return the borrow amount which is calculated from the below formula
   * borrow shares = (_amount * total borrow shares) / total borrows
   * if the calculated borrow shares = 10.9 then the borrow shares = 10
   */
  function calculateRoundDownBorrowShareAmount(ERC20 _token, uint256 _amount)
    internal
    view
    returns (uint256)
  {
    Pool storage pool = pools[address(_token)];
    if (pool.totalBorrowShares == 0) {
      return 0;
    }
    return (_amount * pool.totalBorrowShares) / pool.totalBorrows;
  }

  /**
   * @dev calculate liquidity share amount (round-up)
   * @param _token the ERC20 token of the pool
   * @param _amount the amount of liquidity to calculate the liquidity shares
   * @return the liquidity shares which is calculated from the below formula
   * liquidity shares = ((amount * total liquidity shares) / total liquidity
   * if the calculated liquidity shares = 10.1 then the liquidity shares = 11
   */
  function calculateRoundUpLiquidityShareAmount(ERC20 _token, uint256 _amount)
    internal
    view
    returns (uint256)
  {
    Pool storage pool = pools[address(_token)];
    uint256 poolTotalLiquidityShares = pool.shareToken.totalSupply();
    uint256 poolTotalLiquidity = getTotalLiquidity(_token);
    // Liquidity share amount of the first depositing is equal to amount
    if (poolTotalLiquidity == 0 || poolTotalLiquidityShares == 0) {
      return _amount;
    }
    return divCeil(_amount * poolTotalLiquidityShares, poolTotalLiquidity);
  }

  /**
   * @dev calculate liquidity amount (round-down)
   * @param _token the ERC20 token of the pool
   * @param _shareAmount the liquidity shares to calculate the amount of liquidity
   * @return the amount of liquidity which is calculated from the below formula
   * liquidity amount = (_shareAmount * total liquidity) / total liquidity shares
   * if the calculated liquidity amount = 10.9 then the liquidity amount = 10
   */
  function calculateRoundDownLiquidityAmount(ERC20 _token, uint256 _shareAmount)
    internal
    view
    returns (uint256)
  {
    Pool storage pool = pools[address(_token)];
    uint256 poolTotalLiquidityShares = pool.shareToken.totalSupply();
    if (poolTotalLiquidityShares == 0) {
      return 0;
    }
    return (_shareAmount * getTotalLiquidity(_token)) / poolTotalLiquidityShares;
  }

  /**
   * @dev calculate borrow amount (round-up)
   * @param _token the ERC20 token of the pool
   * @param _shareAmount the borrow shares to calculate the amount of borrow
   * @return the amount of borrowing which is calculated from the below formula
   * borrowing amount = (share amount * total borrows) / total borrow shares
   * if the calculated borrowing amount = 10.1 then the borrowing amount = 11
   */
  function calculateRoundUpBorrowAmount(ERC20 _token, uint256 _shareAmount)
    internal
    view
    returns (uint256)
  {
    Pool storage pool = pools[address(_token)];
    if (pool.totalBorrows == 0 || pool.totalBorrowShares == 0) {
      return _shareAmount;
    }
    return divCeil(_shareAmount * pool.totalBorrows, pool.totalBorrowShares);
  }

  /**
   * @dev get user account details
   * @param _user the address of the user to get the account details
   * return totalLiquidityBalanceBase - the value of user's total liquidity,
   * totalCollateralBalanceBase - the value of user's total collateral,
   * totalBorrowBalanceBase - the value of user's total borrow
   */
  function getUserAccount(address _user)
    public
    view
    returns (
      uint256 totalLiquidityBalanceBase,
      uint256 totalCollateralBalanceBase,
      uint256 totalBorrowBalanceBase
    )
  {
    for (uint256 i = 0; i < tokenList.length; i++) {
      ERC20 _token = tokenList[i];
      Pool storage pool = pools[address(_token)];
      // get user pool data
      (
        uint256 compoundedLiquidityBalance,
        uint256 compoundedBorrowBalance,
        bool userUsePoolAsCollateral
      ) = getUserPoolData(_user, _token);

      if (compoundedLiquidityBalance != 0 || compoundedBorrowBalance != 0) {
        uint256 collateralPercent = pool.poolConfig.getCollateralPercent();
        uint256 poolPricePerUnit = getPriceWBNB(address(_token));
        require(poolPricePerUnit > 0, "TIFI: PRICE_INVALID");
        uint256 liquidityBalanceBase = (poolPricePerUnit * compoundedLiquidityBalance) / 1e18;
        totalLiquidityBalanceBase += liquidityBalanceBase;
        // This pool can use as collateral when collateralPercent more than 0.
        if (collateralPercent > 0 && userUsePoolAsCollateral) {
          totalCollateralBalanceBase += (liquidityBalanceBase * collateralPercent) / 1e18;
        }
        totalBorrowBalanceBase += (poolPricePerUnit * compoundedBorrowBalance) / 1e18;
      }
    }
  }

  /**
   * @dev check is the user account is still healthy
   * Traverse a token list to visit all ERC20 token pools then accumulate 3 balance values of the user:
   * -----------------------------
   * 1. user's total liquidity balance. Accumulate the user's liquidity balance of all ERC20 token pools
   * 2. user's total borrow balance. Accumulate the user's borrow balance of all ERC20 token pools
   * 3. user's total collateral balance. each ERC20 token has the different max loan-to-value (collateral percent) or the percent of
   * liquidity that can actually use as collateral for the borrowing.
   * e.g. if B token has 75% collateral percent means the collateral balance is 75 if the user's has 100 B token balance
   * -----------------------------
   * the account is still healthy if total borrow value is less than total collateral value. This means the user's collateral
   * still cover the user's loan. In case of total borrow value is more than total collateral value then user's account is not healthy.
   * @param _user the address of the user that will check the account health status
   * @return the boolean that represent the account health status. Returns true if account is still healthy, false if account is not healthy.
   */
  function isAccountHealthy(address _user) public view override returns (bool) {
    (, uint256 totalCollateralBalanceBase, uint256 totalBorrowBalanceBase) = getUserAccount(_user);

    return totalBorrowBalanceBase <= totalCollateralBalanceBase;
  }

  function totalBorrowInBNB(ERC20 _token) public view returns (uint256) {
    require(address(getPrice) != address(0), "TIFI: INVALID_GETPRICE");
    uint256 tokenPricePerUnit = getPriceWBNB(address(_token));
    require(tokenPricePerUnit > 0, "TIFI: PRICE_INVALID");
    return tokenPricePerUnit * pools[address(_token)].totalBorrows;
  }

  /**
   * @dev deposit the ERC20 token to the pool
   * @param _token the ERC20 token of the pool that user want to deposit
   * @param _amount the deposit amount
   * User can call this function to deposit their ERC20 token to the pool. user will receive the share token of that ERC20 token
   * which represent the liquidity shares of the user. Providing the liquidity will receive an interest from the the borrower as an incentive.
   * e.g. Alice deposits 10 Hello tokens to the pool.
   * if 1 Hello token shares equals to 2 Hello tokens then Alice will have 5 Hello token shares from 10 Hello tokens depositing.
   * User will receive the liquidity shares in the form of TiFiPoolShare token so Alice will have 5 tifiHello on her wallet
   * for representing her shares.
   */
  function deposit(ERC20 _token, uint256 _amount)
    external
    nonReentrant
    updatePoolWithInterestsAndTimestamp(_token)
  {
    Pool storage pool = pools[address(_token)];
    require(pool.status == PoolStatus.ACTIVE, "TIFI: INVALID_POOL_STATE");
    require(_amount > 0, "TIFI: INVALID_DEPOSIT_AMOUNT");

    // 1. Calculate liquidity share amount
    uint256 shareAmount = calculateRoundDownLiquidityShareAmount(_token, _amount);

    // 2. Mint TiFiPoolShare token to user equal to liquidity share amount
    pool.shareToken.mint(msg.sender, shareAmount);

    // 3. transfer user deposit liquidity to the pool
    _token.safeTransferFrom(msg.sender, address(this), _amount);

    emit Deposit(address(_token), msg.sender, shareAmount, _amount);
  }

  /**
   * @dev borrow the ERC20 token from the pool
   * @param _token the ERC20 token of the pool that user want to borrow
   * @param _amount the borrow amount
   * User can call this function to borrow the ERC20 token from the pool. This function will
   * convert the borrow amount to the borrow shares then accumulate borrow shares of this user
   * of this ERC20 pool then set to user data on that pool state.
   * e.g. Bob borrows 10 Hello tokens from the Hello token pool.
   * if 1 borrow shares of Hello token equals to 5 Hello tokens then the lending contract will
   * set Bob's borrow shares state with 2 borrow shares. Bob will receive 10 Hello tokens.
   */
  function borrow(ERC20 _token, uint256 _amount)
    external
    nonReentrant
    updatePoolWithInterestsAndTimestamp(_token)
  {
    Pool storage pool = pools[address(_token)];
    require(pool.status == PoolStatus.ACTIVE, "TIFI: INVALID_POOL_STATE");
    require(
      _amount > 0 && _amount <= getTotalAvailableLiquidity(_token),
      "TIFI: INVALID_DEPOSIT_AMOUNT"
    );

    // 1. calculate borrow share amount
    uint256 borrowShare = calculateRoundUpBorrowShareAmount(_token, _amount);

    // 2. update pool state
    pool.totalBorrows += _amount;
    pool.totalBorrowShares += borrowShare;

    // 3. update user state
    UserPoolData storage userData = userPoolData[msg.sender][address(_token)];
    userData.borrowShares += borrowShare;

    // 4. transfer borrowed token from pool to user
    _token.safeTransfer(msg.sender, _amount);

    // 5. check account health, this transaction will revert if the account of this user is not healthy
    require(isAccountHealthy(msg.sender), "TIFI: ACCOUNT_UNHEALTHY");
    emit Borrow(address(_token), msg.sender, borrowShare, _amount);
  }

  /**
   * @dev repay the ERC20 token to the pool equal to repay shares
   * @param _token the ERC20 token of the pool that user want to repay
   * @param _share the amount of borrow shares thet user want to repay
   * Internal function that do the repay. If Alice want to repay 10 borrow shares then the repay shares is 10.
   * this function will repay the ERC20 token of Alice equal to repay shares value to the pool.
   * If 1 repay shares equal to 2 Hello tokens then Alice will repay 20 Hello tokens to the pool. the Alice's
   * borrow shares will be decreased.
   */
  function repayInternal(ERC20 _token, uint256 _share) internal {
    Pool storage pool = pools[address(_token)];
    require(pool.status == PoolStatus.ACTIVE, "TIFI: INVALID_POOL_STATE");
    UserPoolData storage userData = userPoolData[msg.sender][address(_token)];
    uint256 paybackShares = _share;
    if (paybackShares > userData.borrowShares) {
      paybackShares = userData.borrowShares;
    }
    // 1. calculate round up payback token
    uint256 paybackAmount = calculateRoundUpBorrowAmount(_token, paybackShares);
    // 2. update pool state
    pool.totalBorrows -= paybackAmount;
    pool.totalBorrowShares -= paybackShares;
    // 3. update user state
    userData.borrowShares -= paybackShares;
    // 4. transfer payback tokens to the pool
    _token.safeTransferFrom(msg.sender, address(this), paybackAmount);
    emit Repay(address(_token), msg.sender, paybackShares, paybackAmount);
  }

  /**
   * @dev repay the ERC20 token to the pool equal to repay shares
   * @param _token the ERC20 token of the pool that user want to repay
   * @param _share the amount of borrow shares thet user want to repay
   * User can call this function to repay the ERC20 token to the pool.
   * This function will do the repay equal to repay shares
   */
  function repayByShare(ERC20 _token, uint256 _share)
    external
    nonReentrant
    updatePoolWithInterestsAndTimestamp(_token)
  {
    repayInternal(_token, _share);
  }

  /**
   * @dev withdraw the ERC20 token from the pool
   * @param _token the ERC20 token of the pool that user want to withdraw
   * @param _share the share Token amount that user want to withdraw
   * When user withdraw their liquidity shares or share Token, they will receive the ERC20 token from the pool
   * equal to the tifiHello value.
   * e.g. Bob want to withdraw 10 tifiHello. If 1 tifiHello equal to 10 Hello tokens then Bob will receive
   * 100 Hello tokens after withdraw. Bob's tifiHello will be burned.
   * Note: Bob cannot withdraw his alHello if his account is not healthy which means he uses all of his liquidity as
   * collateral to cover his loan so he cannot withdraw or transfer his tifiHello.
   */
  function withdraw(ERC20 _token, uint256 _share)
    external
    nonReentrant
    updatePoolWithInterestsAndTimestamp(_token)
  {
    Pool storage pool = pools[address(_token)];
    uint256 tifiBalance = pool.shareToken.balanceOf(msg.sender);
    require(
      pool.status == PoolStatus.ACTIVE || pool.status == PoolStatus.CLOSED,
      "TIFI: INVALID_POOL_STATE"
    );
    uint256 withdrawShares = _share;
    if (withdrawShares > tifiBalance) {
      withdrawShares = tifiBalance;
    }

    // 1. calculate liquidity amount from shares
    uint256 withdrawAmount = calculateRoundDownLiquidityAmount(_token, withdrawShares);

    // 2. burn TiFi pool share tokens of user equal to shares
    pool.shareToken.burn(msg.sender, withdrawShares);

    // 3. transfer ERC20 tokens to user account
    _token.transfer(msg.sender, withdrawAmount);

    // 4. Check account health, this transaction wil revert if the account of this user is not healthy
    require(isAccountHealthy(msg.sender), "TIFI: ACCOUNT_UNHEALTHY");
    emit Withdraw(address(_token), msg.sender, withdrawShares, withdrawAmount);
  }

  /**
   * @dev liquidate the unhealthy user account (internal)
   * @param _user the address of the user that liquidator want to liquidate
   * @param _token the token that liquidator want to liquidate
   * @param _liquidateShares the amount of token shares that liquidator want to liquidate
   * @param _collateral the ERC20 token of the pool that liquidator will receive as a reward
   * e.g. Alice account is not healthy. Bob saw Alice account then want to liquidate 10 Hello borrow shares of Alice account
   * and want to get the Seeyou tokens as the collateral. The steps that will happen is below:
   * 1. Bob calls the liquidate function with _user is Alice address, _token is Hello token,
   * _liquidateShare is 10, _collateral is Seeyou token to liquidate Alice account.
   * 2. Contract check if Alice account is in an unhealthy state or not. If Alice account is
   * still healthy, Bob cannot liquidate this account then this transaction will be revert.
   * 3. Contract check if the collateral that Bob has requested enable for the liquidation reward both on
   * pool enabling and Alice enabling.
   * 4. Bob can liquidate Alice account if Alice has been borrowing Hello tokens from the pool.
   * 5. Bob can liquidate from 0 to the max liquidate shares which equal to 50% of Alice's Hello borrow share.
   * 6. Contract calculates the amount of collateral that Bob will receive as the rewards to convert to
   * the amount of Seeyou shares. Seeyou shares is the alSeeyou token.
   * 7. Bob pays Hello tokens equal to 10 Hello shares. If 1 Hello shares equal to 10 Hello tokens then Bob will
   * pay 100 Hello token to the pool
   * 8. The borrowing shares of the Hello token on Alice account will be decreased. The alSeeyou of Alice will be burned.
   * 9. Bob will get 105 alSeeyou tokens.
   * 10. Bob can withdraw the alHello tokens later to get the Hello tokens from the pool.
   * Note: Hello and Seeyou are the imaginary ERC20 token.
   */
  function liquidateInternal(
    address _user,
    ERC20 _token,
    uint256 _liquidateShares,
    ERC20 _collateral
  ) internal {
    Pool storage pool = pools[address(_token)];
    Pool storage collateralPool = pools[address(_collateral)];
    UserPoolData storage userCollateralData = userPoolData[_user][address(_collateral)];
    UserPoolData storage userTokenData = userPoolData[_user][address(_token)];
    require(
      pool.status == PoolStatus.ACTIVE || pool.status == PoolStatus.CLOSED,
      "TIFI: INVALID_POOL_STATE"
    );

    // 1. check account health of user to make sure that liquidator can liquidate this account
    require(!isAccountHealthy(_user), "TIFI: ACCOUNT_IS_HEALTHY");

    // 2. check if the user enables collateral
    require(!userCollateralData.disableUseAsCollateral, "TIFI: COLLATERAL_DISABLED");

    // 3. check if the token pool enable to use as collateral
    require(collateralPool.poolConfig.getCollateralPercent() > 0, "TIFI: POOL_IS_NOT_COLLATERAL");

    // 4. check if the user has borrowed tokens that liquidator want to liquidate
    require(userTokenData.borrowShares > 0, "TIFI: USER_DID_NOT_BORROW");

    // 5. calculate liquidate amount and shares
    uint256 maxPurchaseShares = (userTokenData.borrowShares * CLOSE_FACTOR) / 1e18;
    uint256 liquidateShares = _liquidateShares;
    if (liquidateShares > maxPurchaseShares) {
      liquidateShares = maxPurchaseShares;
    }
    uint256 liquidateAmount = calculateRoundUpBorrowAmount(_token, liquidateShares);

    // 6. calculate collateral amount and shares
    uint256 collateralAmount = calculateCollateralAmount(_token, liquidateAmount, _collateral);
    uint256 collateralShares = calculateRoundUpLiquidityShareAmount(_collateral, collateralAmount);

    // 7. transfer liquidate amount to the pool
    _token.safeTransferFrom(msg.sender, address(this), liquidateAmount);

    // 8. burn share token of user equal to collateral shares
    require(
      collateralPool.shareToken.balanceOf(_user) > collateralShares,
      "TIFI: INSUFFICIENT_COLLATERAL"
    );
    collateralPool.shareToken.burn(_user, collateralShares);

    // 9. mint share token equal to collateral shares to liquidator
    collateralPool.shareToken.mint(msg.sender, collateralShares);

    // 10. update pool state
    pool.totalBorrows -= liquidateAmount;
    pool.totalBorrowShares -= liquidateShares;

    // 11. update user state
    userTokenData.borrowShares -= liquidateShares;

    emit Liquidate(
      _user,
      address(_token),
      address(_collateral),
      liquidateAmount,
      liquidateShares,
      collateralAmount,
      collateralShares,
      msg.sender
    );
  }

  /**
   * @dev liquidate the unhealthy user account
   * @param _user the address of the user that liquidator want to liquidate
   * @param _token the token that liquidator whan to liquidate
   * @param _liquidateShares the amount of token shares that liquidator want to liquidate
   * @param _collateral the ERC20 token of the pool that liquidator will receive as a reward
   * If the user's account health is not healthy, anothor user can become to the liquidator to liquidate
   * the user account then got the collateral as a reward.
   */
  function liquidate(
    address _user,
    ERC20 _token,
    uint256 _liquidateShares,
    ERC20 _collateral
  )
    external
    nonReentrant
    updatePoolWithInterestsAndTimestamp(_token)
    updatePoolWithInterestsAndTimestamp(_collateral)
  {
    require(!liquidatorWhitelisted || liquidatorWhitelist[msg.sender], "TIFI: UNAUTHORIZED");
    liquidateInternal(_user, _token, _liquidateShares, _collateral);
  }

  /**
   * @dev calculate collateral amount that the liquidator will receive after the liquidation
   * @param _token the token that liquidator want to liquidate
   * @param _liquidateAmount the amount of token that liquidator want to liquidate
   * @param _collateral the ERC20 token of the pool that liquidator will receive as a reward
   * @return the collateral amount of the liquidation
   * This function will be call on liquidate function to calculate the collateral amount that
   * liquidator will get after the liquidation. Liquidation bonus is expressed in percent. the collateral amount
   * depends on each pool. If the Hello pool has liquidation bonus equal to 105% then the collateral value is
   * more than the value of liquidated tokens around 5%. the formula is below:
   * collateral amount = (token price * liquidate amount * liquidation bonus percent) / collateral price
   */
  function calculateCollateralAmount(
    ERC20 _token,
    uint256 _liquidateAmount,
    ERC20 _collateral
  ) internal view returns (uint256) {
    require(address(getPrice) != address(0), "TIFI: INVALID_GETPRICE");
    uint256 tokenPricePerUnit = getPriceWBNB(address(_token));
    require(tokenPricePerUnit > 0, "TIFI: TOKEN_PRICE_INVALID");
    uint256 collateralPricePerUnit = getPriceWBNB(address(_collateral));
    require(collateralPricePerUnit > 0, "TIFI: COLLATERAL_PRICE_INVALID");
    uint256 liquidationBonus = pools[address(_token)].poolConfig.getLiquidationBonusPercent();
    return
      (tokenPricePerUnit * _liquidateAmount * liquidationBonus) / collateralPricePerUnit / 1e18;
  }

  /**
   * @dev set reserve percent for admin
   * @param _reservePercent the percent of pool reserve
   */
  function setReservePercent(uint256 _reservePercent) external onlyOwner {
    reservePercent = _reservePercent;
  }

  /**
   * @dev withdraw function for admin to get the reserves
   * @param _token the ERC20 token of the pool to withdraw
   * @param _amount amount to withdraw
   */
  function withdrawReserve(ERC20 _token, uint256 _amount)
    external
    nonReentrant
    updatePoolWithInterestsAndTimestamp(_token)
    onlyOwner
  {
    Pool storage pool = pools[address(_token)];
    uint256 poolBalance = _token.balanceOf(address(this));
    require(_amount <= poolBalance, "TIFI: INSUFFICIENT_BALANCE");
    // admin can't withdraw more than pool's reserve
    require(_amount <= pool.poolReserves, "TIFI: INSUFFICIENT_POOL_RESERVES");
    _token.safeTransfer(msg.sender, _amount);
    pool.poolReserves -= _amount;
  }
}