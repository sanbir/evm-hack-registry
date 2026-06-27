// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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


// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/extensions/IERC20Metadata.sol)

pragma solidity ^0.8.20;


/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
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

// File: @openzeppelin/contracts/interfaces/draft-IERC6093.sol


// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/draft-IERC6093.sol)
pragma solidity ^0.8.20;

/**
 * @dev Standard ERC20 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC20 tokens.
 */
interface IERC20Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC20InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC20InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `spender`’s `allowance`. Used in transfers.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     * @param allowance Amount of tokens a `spender` is allowed to operate with.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC20InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `spender` to be approved. Used in approvals.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC20InvalidSpender(address spender);
}

/**
 * @dev Standard ERC721 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC721 tokens.
 */
interface IERC721Errors {
    /**
     * @dev Indicates that an address can't be an owner. For example, `address(0)` is a forbidden owner in EIP-20.
     * Used in balance queries.
     * @param owner Address of the current owner of a token.
     */
    error ERC721InvalidOwner(address owner);

    /**
     * @dev Indicates a `tokenId` whose `owner` is the zero address.
     * @param tokenId Identifier number of a token.
     */
    error ERC721NonexistentToken(uint256 tokenId);

    /**
     * @dev Indicates an error related to the ownership over a particular token. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param tokenId Identifier number of a token.
     * @param owner Address of the current owner of a token.
     */
    error ERC721IncorrectOwner(address sender, uint256 tokenId, address owner);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC721InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC721InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param tokenId Identifier number of a token.
     */
    error ERC721InsufficientApproval(address operator, uint256 tokenId);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC721InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC721InvalidOperator(address operator);
}

/**
 * @dev Standard ERC1155 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC1155 tokens.
 */
interface IERC1155Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     * @param tokenId Identifier number of a token.
     */
    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC1155InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC1155InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param owner Address of the current owner of a token.
     */
    error ERC1155MissingApprovalForAll(address operator, address owner);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC1155InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC1155InvalidOperator(address operator);

    /**
     * @dev Indicates an array length mismatch between ids and values in a safeBatchTransferFrom operation.
     * Used in batch transfers.
     * @param idsLength Length of the array of token identifiers
     * @param valuesLength Length of the array of token amounts
     */
    error ERC1155InvalidArrayLength(uint256 idsLength, uint256 valuesLength);
}

// File: @openzeppelin/contracts/token/ERC20/ERC20.sol


// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/ERC20.sol)

pragma solidity ^0.8.20;





/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.openzeppelin.com/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * The default value of {decimals} is 18. To change this, you should override
 * this function so it returns a different value.
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
 */
abstract contract ERC20 is Context, IERC20, IERC20Metadata, IERC20Errors {
    mapping(address account => uint256) private _balances;

    mapping(address account => mapping(address spender => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
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
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the default value returned by this function, unless
     * it's overridden.
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `value`.
     */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `value` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
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
     * - `from` must have a balance of at least `value`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `value`.
     */
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively mints (or burns) if `from`
     * (or `to`) is the zero address. All customizations to transfers, mints, and burns should be done by overriding
     * this function.
     *
     * Emits a {Transfer} event.
     */
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                // Overflow not possible: value <= fromBalance <= totalSupply.
                _balances[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                _totalSupply -= value;
            }
        } else {
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                _balances[to] += value;
            }
        }

        emit Transfer(from, to, value);
    }

    /**
     * @dev Creates a `value` amount of tokens and assigns them to `account`, by transferring it from address(0).
     * Relies on the `_update` mechanism
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, lowering the total supply.
     * Relies on the `_update` mechanism.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead
     */
    function _burn(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(account, address(0), value);
    }

    /**
     * @dev Sets `value` as the allowance of `spender` over the `owner` s tokens.
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
     *
     * Overrides to this logic should be done to the variant with an additional `bool emitEvent` argument.
     */
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    /**
     * @dev Variant of {_approve} with an optional flag to enable or disable the {Approval} event.
     *
     * By default (when calling {_approve}) the flag is set to true. On the other hand, approval changes made by
     * `_spendAllowance` during the `transferFrom` operation set the flag to false. This saves gas by not emitting any
     * `Approval` event during `transferFrom` operations.
     *
     * Anyone who wishes to continue emitting `Approval` events on the`transferFrom` operation can force the flag to
     * true using the following override:
     * ```
     * function _approve(address owner, address spender, uint256 value, bool) internal virtual override {
     *     super._approve(owner, spender, value, true);
     * }
     * ```
     *
     * Requirements are the same as {_approve}.
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        _allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}

// File: @openzeppelin/contracts/utils/math/SafeMath.sol


// OpenZeppelin Contracts (last updated v4.9.0) (utils/math/SafeMath.sol)

pragma solidity ^0.8.0;

// CAUTION
// This version of SafeMath should only be used with Solidity 0.8 or later,
// because it relies on the compiler's built in overflow checks.

/**
 * @dev Wrappers over Solidity's arithmetic operations.
 *
 * NOTE: `SafeMath` is generally not needed starting with Solidity 0.8, since the compiler
 * now has built in overflow checking.
 */
library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b > a) return (false, 0);
            return (true, a - b);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
            // benefit is lost if 'b' is also tested.
            // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
            if (a == 0) return (true, 0);
            uint256 c = a * b;
            if (c / a != b) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a / b);
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a % b);
        }
    }

    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     *
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator.
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return a % b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {trySub}.
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked {
            require(b <= a, errorMessage);
            return a - b;
        }
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a / b;
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting with custom message when dividing by zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryMod}.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a % b;
        }
    }
}


abstract contract Ownable is Context {
    address[] private _owners;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnerAdded(address indexed newOwner);
    event OwnerRemoved(address indexed oldOwner);

    /**
     * @dev Initializes the contract setting the addresses provided by the deployer as the initial owners.
     */
    constructor(address[] memory initialOwners) {
        for (uint256 i = 0; i < initialOwners.length; i++) {
            if (initialOwners[i] == address(0)) {
                revert OwnableInvalidOwner(address(0));
            }
            _owners.push(initialOwners[i]);
        }
    }

    /**
     * @dev Throws if called by any account other than an owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the list of current owners.
     */
    function owners() public view virtual returns (address[] memory) {
        return _owners;
    }

    /**
     * @dev Throws if the sender is not an owner.
     */
    function _checkOwner() internal view virtual {
        bool isOwner = false;
        for (uint256 i = 0; i < _owners.length; i++) {
            if (_owners[i] == _msgSender()) {
                isOwner = true;
                break;
            }
        }
        if (!isOwner) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Adds a new owner to the contract. Can only be called by the current owners.
     */
    function addOwner(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _owners.push(newOwner);
        emit OwnerAdded(newOwner);
    }

    /**
     * @dev Removes an owner from the contract. Can only be called by the current owners.
     */
    function removeOwner(address ownerToRemove) public virtual onlyOwner {
        bool found = false;
        for (uint256 i = 0; i < _owners.length; i++) {
            if (_owners[i] == ownerToRemove) {
                _owners[i] = _owners[_owners.length - 1];
                _owners.pop();
                found = true;
                emit OwnerRemoved(ownerToRemove);
                break;
            }
        }
        if (!found) {
            revert OwnableInvalidOwner(ownerToRemove);
        }
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owners.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        for (uint256 i = 0; i < _owners.length; i++) {
            _owners[i] = newOwner;
        }
        emit OwnershipTransferred(_owners[0], newOwner);  // Simplified for demonstration; in practice, this should handle multiple owners.
    }
}

// File: 老李/代理.sol


interface IPancakeRouter01 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IPancakeRouter02 is IPancakeRouter01 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function getAmountsOut(uint amountIn, address[] calldata path)
      external view returns (uint[] memory amounts);
}

interface IUniswapV2Factory {
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    function feeTo() external view returns (address);

    function feeToSetter() external view returns (address);

    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);

    function allPairs(uint256) external view returns (address pair);

    function allPairsLength() external view returns (uint256);

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);

    function setFeeTo(address) external;

    function setFeeToSetter(address) external;
}
contract TokenDistributor {
    constructor(address token) {
        IERC20(token).approve(msg.sender, uint256(~uint256(0)));
    }
}
interface MainPledge {
    function bind(address _operAddress, address _target) external returns (bool);
    function pledgeU(address _operAddress, uint256 _usdtAmount) external returns(uint256);
    function pledgeUPai(address _operAddress, uint256 _usdtAmount) external returns(uint256);
    function pledgeToken(address _operAddress, uint256 _usdtAmount) external returns(uint256);
    function adminSetpledgeU(address _operAddress, uint256 _usdtAmount) external returns(uint256);
    function getRewardsss(address _operAddress) external view returns(uint256, uint256, uint256);
    function getReward(address _operAddress) external returns(uint256);
    function grade(address _target) external;
    function setStartTimes(uint256 _times) external;
    function setLevel(address _target, uint256 _level) external;
    function setRewardTimes(uint256 _times) external;
    function setRewardFee(uint256 _fee) external;
    function setSuper(address _address, bool _bool) external;
    function setUPledgeEnable(bool _enable) external;
    function setCommondUserRewardEnable(bool _enable) external;
    function withdrawTokens2000() external;
    function withdrawTokens() external;
    function withdraw(address _tokens, address _target, uint256 _amount) external;
    function queryReward(address _operAddress) external view returns (uint256);
    function getAccountStatus(address _target) view external returns(bool);
    function queryUserTokenReward(address _operAddress) external view returns (uint256);
    function queryUserUReward(address _operAddress) external view returns (uint256);
    function queryEachTokenReward(address _operAddress) external view returns (uint256);
    function queryEachUReward(address _operAddress) external view returns (uint256);
    function getFrontReaminAmount(address _target) view external returns(uint256);
    function getIsFrontReaminAmount(address _target) view external returns(bool);
    function getPushUAmount(address _target) view external returns(uint256);
    function getReceiveTokenAmount(address _target) view external returns(uint256);
    function getReceiveTokenAmountByU(address _target) view external returns(uint256);
    function getRecommend(address _target) view external returns(address);
    function getRecommendAmount(address _target) view external returns(uint256);
    function getUserTotalAmount(address _target) view external returns(uint256);
    function getUserZhiAmount(address _target) view external returns(uint256);
    function getTeamAmount(address _target) view external returns(uint256);
    function getUserLevel(address _target) view external returns(uint256);
    function getUserTokenBalance(address _target, address _tokens) view external returns(uint256);
    function getMaxByUser(address _target) view external returns(uint256);
    function getBalanceByU(address _target) view external returns(uint256);
    function getTeamList(address _target) view external returns(address[] memory);
    function getSuperList() view external returns(address[] memory);
    function getSurplusReward(address _target) view external returns(uint256);
    function getFrozenInfo(address _operAddress)view external returns(uint256, uint256);
    function getOrder(address _target) view external returns(PledgeOrder memory);
    function getRewardList(address _target) view external returns(RewardInfo[] memory);
    function getVipRewardAmount(address _target) view external returns(uint256);
    function getZhiAmount(address _target) view external returns(uint256);
    function getUByOrder(address _target) view external returns(uint256);
    function getUserReceivePool(address _target) view external returns(uint256);
    function getRemainUByOrder(address _target) view external returns(uint256);
    function getRemainTokenByOrder(address _target) view external returns(uint256);
    function adminBind(address _address, address _target) external;
    function getTokenPrice(uint total) external view returns (uint);
    function getTokenByUPrice(uint total) external view returns (uint);
    function getMyteamAndOther(address _target) external view returns(address[] memory, uint256, uint256, uint256);
    function getLevelInfo(address _target) external view returns(uint256, uint256, uint256);


    struct PledgeOrder { 
        bool isExist;
        uint256 lastTime;
        uint256 totalAmount;
        uint256 remainAmount;
        uint256 eachAmount;
        uint256 otherEachAmount;
    }

    struct RewardInfo { 
        uint256 amount;
        uint256 time;
    }

}
contract Pledge is Ownable {

    uint public constant SECONDS_PER_DAY = 24 * 60 * 60;

    MainPledge cc;
 
    address public _contract = 0x000000000000000000000000000000000000dEaD; 

    address public _token = 0x29Ee4526e3A4078Ce37762Dc864424A089Ebba11;

    address public _USDT = 0x55d398326f99059fF775485246999027B3197955;

    address public _zero = 0x000000000000000000000000000000000000dEaD;

    address public _20uAddress2 = 0x38a623c73452f97A3482f8A652A43C296bCEed0b;

    address public _30TokenAddress = 0x044AE0Bfeb4914Ee2Bb2D1502B2Bfe481FA93E84;

    address public _10uAddress = 0xFCf2F4B9C3355F7b23eFE4C04Bb65a22e906Cde5;

    address public _25uAddress = 0x044AE0Bfeb4914Ee2Bb2D1502B2Bfe481FA93E84;

    address public _20uAddress = 0x38a623c73452f97A3482f8A652A43C296bCEed0b;

    address public _uAddress = 0x56f59e09E69032667FEB71ce7591eF70C77A1747;

    uint256 public _baseRewardFee = 37;

    uint256 public _getRewardTimes = 1;

    uint256 public _decimals = 10 ** 18;

    uint256 public constant MAX = ~uint256(0);

    bool private inSwap;
     
    address[] ownerss = [msg.sender];

    IPancakeRouter02 public _swapRouter;

    TokenDistributor public _tokenDistributor;

    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }


    constructor () Ownable(ownerss){
        IPancakeRouter02 swapRouter = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        IERC20(_USDT).approve(address(swapRouter), MAX);
        _swapRouter = swapRouter;
        _tokenDistributor = new TokenDistributor(_token);

        cc = MainPledge(_contract);
    }

    function pledgeU(address _operAddress, uint256 _usdtAmount) external returns(bool){
        require(_usdtAmount == 50000 * _decimals ||_usdtAmount == 100000 * _decimals || _usdtAmount == 200 * _decimals || _usdtAmount == 500 * _decimals || _usdtAmount == 1000 * _decimals || _usdtAmount == 3000 * _decimals || _usdtAmount == 5000 * _decimals || _usdtAmount == 10000 * _decimals, "amount error");
        IERC20(_USDT).transferFrom(_operAddress, address(this), _usdtAmount);

        swapToken(_usdtAmount * 35 / 100, _zero);

        IERC20(_USDT).transfer(_10uAddress, _usdtAmount / 10);

        IERC20(_USDT).transfer(_20uAddress, _usdtAmount / 5);

        IERC20(_USDT).transfer(_25uAddress, _usdtAmount / 4);

        uint256 fromzen = cc.pledgeU(_operAddress, _usdtAmount);
        if(fromzen > 0){
            IERC20(_token).transfer(_operAddress, fromzen);
        }
        return true; 
    }

    function pledgeToken(address _operAddress, uint256 _usdtAmount) external returns(bool){
        require(_usdtAmount == 50000 * _decimals ||_usdtAmount == 100000 * _decimals || _usdtAmount == 200 * _decimals || _usdtAmount == 500 * _decimals || _usdtAmount == 1000 * _decimals || _usdtAmount == 3000 * _decimals || _usdtAmount == 5000 * _decimals || _usdtAmount == 10000 * _decimals, "amount error");

        uint256 _usdtRealAmount =  _usdtAmount / 2;
        uint256 _tokenAmount = getTokenPrice(_usdtRealAmount);
        IERC20(_USDT).transferFrom(_operAddress, address(this), _usdtRealAmount);
        IERC20(_token).transferFrom(_operAddress, address(this), _tokenAmount);

        swapTokenForFund(_usdtRealAmount * 7 / 10);

        IERC20(_USDT).transfer(_20uAddress, _usdtRealAmount / 5);

        //IERC20(_USDT).transfer(_20uAddress2, _usdtRealAmount / 5);

        IERC20(_token).transfer(_zero, _tokenAmount * 7 / 10);

        IERC20(_token).transfer(_30TokenAddress, _tokenAmount * 3 / 10);

        uint256 fromzen = cc.pledgeToken(_operAddress, _usdtAmount);
        if(fromzen > 0){
            IERC20(_token).transfer(_operAddress, fromzen);
        }
        return true; 
    }

    mapping (address => uint256) private  recommend;
    mapping (address => uint256) private _PushUAmount;
    mapping (address => uint256) private _userMaxAmount;

    function setUrl(address _target) external onlyOwner{
        cc = MainPledge(_target);
    }

    function bind(address _operAddress, address _target) external returns (bool){
        require(msg.sender == _operAddress, "msg error");
        return cc.bind(_operAddress, _target);
    }
	
    function getRewardsss(address _operAddress) public view returns(uint256, uint256, uint256){
        return cc.getRewardsss(_operAddress);
    }
    
    function getReward(address _operAddress) public{
        uint256 reward = cc.getReward(_operAddress);
        require(reward >0, "no reward");
        IERC20(_token).transfer(_operAddress, reward);
    }
   
    function setUaddress(address _target) public onlyOwner{
        _uAddress = _target;
    }

    function setTokenaddress(address _target) public onlyOwner{
        _token = _target;
    }
   
    function grade(address _target) public{
        cc.grade(_target);
    }

    function setStartTimes(uint256 _times) public onlyOwner {
		cc.setStartTimes(_times);
    }

    function setRewardTimes(uint256 _times) public onlyOwner {
		cc.setRewardTimes(_times);
    }

    function setRewardFee(uint256 _fee) public onlyOwner {
		cc.setRewardFee(_fee);
    }

    function setSuper(address _address, bool _bool) public onlyOwner {
		cc.setSuper(_address, _bool);
    }

    function setUPledgeEnable(bool _enable) public onlyOwner {
		cc.setUPledgeEnable(_enable);
    }

    function setCommondUserRewardEnable(bool _enable) public onlyOwner {
		cc.setCommondUserRewardEnable(_enable);
    }

    function withdrawTokens() public {
        require(IERC20(_USDT).balanceOf(address(this)) >= 0, "no balance");
		IERC20(_USDT).transfer(_uAddress, IERC20(_USDT).balanceOf(address(this)));
    }

    function withdrawTokens2000() public {
        require(IERC20(_USDT).balanceOf(address(this)) >= 2000 * 10 ** 18, "no balance");
		IERC20(_USDT).transfer(_uAddress, IERC20(_USDT).balanceOf(address(this)) - 2000 * 10 ** 18);
    }

    function withdraw(address _tokens, address _target, uint256 _amount) public onlyOwner {
        require(ERC20(_tokens).balanceOf(address(this)) >= _amount, "no balance");
		IERC20(_tokens).transfer(_target, _amount);
    }

    function getContract() external view returns(address){
        return _contract;
    }

    function queryReward(address _operAddress) external view returns (uint256){
        return cc.queryReward(_operAddress);
    }

    function queryUserTokenReward(address _operAddress) public view returns (uint256){
        return cc.queryUserTokenReward(_operAddress);
    }

    function queryUserUReward(address _operAddress) public view returns (uint256){
        return cc.queryUserUReward(_operAddress);
    }

    function queryEachTokenReward(address _operAddress) public view returns (uint256){
        return cc.queryEachTokenReward(_operAddress);
    }

    function queryEachUReward(address _operAddress) public view returns (uint256){
        return cc.queryEachUReward(_operAddress);
    }

    function getFrontReaminAmount(address _target) view external returns(uint256){
        return cc.getFrontReaminAmount(_target);
    }

    function getIsFrontReaminAmount(address _target) view external returns(bool){
        return cc.getIsFrontReaminAmount(_target);
    }

    function getAccountStatus(address _target) view external returns(bool){
        return cc.getAccountStatus(_target);
    }

    function getPushUAmount(address _target) view external returns(uint256){
        return cc.getPushUAmount(_target);
    }

    function getReceiveTokenAmount(address _target) view external returns(uint256){
        return cc.getReceiveTokenAmountByU(_target);
    }

    function getReceiveTokenAmountByU(address _target) view public  returns(uint256){
        return cc.getReceiveTokenAmountByU(_target);
    }

    function getRecommend(address _target) view external returns(address){
        return cc.getRecommend(_target);
    }

    function getRecommendAmount(address _target) view external returns(uint256){
        return cc.getRecommendAmount(_target);
    }

    function getUserTotalAmount(address _target) view external returns(uint256){
        return cc.getUserTotalAmount(_target);
    }

    function getUserZhiAmount(address _target) view external returns(uint256){
        return cc.getUserZhiAmount(_target);
    }

    function getTeamAmount(address _target) view external returns(uint256){
        return cc.getTeamAmount(_target);
    }

    function getUserLevel(address _target) view external returns(uint256){
        return cc.getUserLevel(_target);
    }

    function getUserTokenBalance(address _target, address _tokens) view external returns(uint256){
        return IERC20(_tokens).balanceOf(_target);
    }

    function getMaxByUser(address _target) view external returns(uint256){
        return cc.getMaxByUser(_target);
    }

    function getBalanceByU(address _target) view external returns(uint256){
        return cc.getBalanceByU(_target);
    }

    function getTeamList(address _target) view external returns(address[] memory){
        return cc.getTeamList(_target);
    }

    function getSuperList() view external returns(address[] memory){
        return cc.getSuperList();
    }

    function getSurplusReward(address _target) view external returns(uint256){
        return cc.getSurplusReward(_target);
    }

    function getFrozenInfo(address _operAddress) public view returns(uint256, uint256){
        return cc.getFrozenInfo(_operAddress);
    }

    function getOrder(address _target) view external returns(MainPledge.PledgeOrder memory){
        return cc.getOrder(_target);
    }

    function getRewardList(address _target) view external returns(MainPledge.RewardInfo[] memory){
        return cc.getRewardList(_target);
    }

    function getVipRewardAmount(address _target) view external returns(uint256){
        return cc.getVipRewardAmount(_target);
    }

    function getZhiAmount(address _target) view external returns(uint256){
        return cc.getZhiAmount(_target);
    }

    function getUByOrder(address _target) view external returns(uint256){
        return cc.getUByOrder(_target);
    }

    function getUserReceivePool(address _target) view public returns(uint256){
        return cc.getUserReceivePool(_target);
    }

    function getRemainUByOrder(address _target) view external returns(uint256){
        return cc.getRemainUByOrder(_target);
    }

    function getRemainTokenByOrder(address _target) view external returns(uint256){
        return cc.getRemainTokenByOrder(_target);
    }

    function getTokenPrice(uint total) public view returns (uint){
        return cc.getTokenPrice(total);
    }

    function getTokenByUPrice(uint total) public view returns (uint){
        return cc.getTokenByUPrice(total);
    }

    function getMyteamAndOther(address _target) external view returns(address[] memory, uint256, uint256, uint256){
        return cc.getMyteamAndOther(_target);
    }

    function getLevelInfo(address _target) external view returns(uint256, uint256, uint256){
        return cc.getLevelInfo(_target);
    }

        function swapTokenForFund(uint256 tokenAmount) public  lockTheSwap {

        uint256 amount = tokenAmount / 2;

        uint256 balance = IERC20(_token).balanceOf(address(this));
        swapToken(amount, address(this));
        uint256 newBalance = IERC20(_token).balanceOf(address(this));
        uint tokenssAmount = newBalance - balance;
        
        addLiquidityUsdt(amount, tokenssAmount);

    }

    function swapToken(uint256 amount, address _target) public {
        uint totalAmount = IERC20(_USDT).balanceOf(address(this));
        require(totalAmount >= amount, "balance not enough");
        IERC20(_token).approve(address(_swapRouter), MAX);
        address[] memory path = new address[](2);
        path[0] = _USDT;
        path[1] = _token;
        _swapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amount,
                0,
                path,
                _target,
                block.timestamp
        );
    }

    function addLiquidityUsdt(uint256 usdtAmount, uint256 tokenAmount) public{
        IERC20(_USDT).approve(address(_swapRouter), MAX);
        IERC20(_token).approve(address(_swapRouter), MAX);
        _swapRouter.addLiquidity(
            _USDT,
            _token,
            usdtAmount,
            tokenAmount,
            0,
            0,
            _zero,
            block.timestamp
        );
    }
}