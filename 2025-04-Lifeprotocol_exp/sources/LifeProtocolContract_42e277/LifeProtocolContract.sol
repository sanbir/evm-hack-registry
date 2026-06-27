// SPDX-License-Identifier: MIT
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

// File: @openzeppelin/contracts/interfaces/draft-IERC6093.sol


// OpenZeppelin Contracts (last updated v5.1.0) (interfaces/draft-IERC6093.sol)
pragma solidity ^0.8.20;

/**
 * @dev Standard ERC-20 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-20 tokens.
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
 * @dev Standard ERC-721 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-721 tokens.
 */
interface IERC721Errors {
    /**
     * @dev Indicates that an address can't be an owner. For example, `address(0)` is a forbidden owner in ERC-20.
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
 * @dev Standard ERC-1155 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-1155 tokens.
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


// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/ERC20.sol)

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
 * conventional and does not conflict with the expectations of ERC-20
 * applications.
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
     * Skips emitting an {Approval} event indicating an allowance update. This is not
     * required by the ERC. See {xref-ERC20-_approve-address-address-uint256-bool-}[_approve].
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
     *
     * ```solidity
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

// File: LIFE Token.sol


pragma solidity ^0.8.0;




contract LifeToken is ERC20, Ownable, ReentrancyGuard {

    constructor(
        string memory name,
        string memory symbol,
        address initialOwner,
        address lifeProtocol,
        address lifeProtocolTreasury,
        address teamAddress
    ) ERC20(name, symbol) Ownable(initialOwner) {

        uint256 totalSupply = 21_000_000 * (10**18); 
        _mint(initialOwner, totalSupply);
        uint256 reserveAmount = (totalSupply * 70) / 100;
        uint256 treasuryAmount = (totalSupply * 20) / 100;
        uint256 teamAmount = (totalSupply * 10) / 100;

        _transfer(initialOwner, lifeProtocol, reserveAmount);
        _transfer(initialOwner, lifeProtocolTreasury, treasuryAmount);
        _transfer(initialOwner, teamAddress, teamAmount);
    }
    
}

// File: LIFE Protocol.sol


pragma solidity ^0.8.0;





contract LifeProtocolContract is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    LifeToken public lifeToken;
    IERC20 public UsdtToken;
    address public LifeProtocolAffiliate;
    uint256 public minTradeAmount;
    uint256 public maxTradeAmount;
    uint256 public sellOrderCounter;
    uint256 public currentPrice ;
    uint256 public buyBackReserve;
    uint256 private remainingSupply; 
    uint256 private queueSupply; 
    bytes32 public currentSellOrderId;

    mapping(bytes32 => SellOrder) public sellOrders;
    mapping(address => bytes32[]) public sellerOrders;

    // Events
    event PriceAdjusted(uint256 newPrice);
    event BuyBackExecuted(uint256 amount, uint256 price);
    event SellOrderCancelled(bytes32 indexed sellOrderId);
    event Buy(address indexed buyer, uint256 amount, uint256 price);
    event BuyBackReserveContribution(address indexed sender, uint256 amount);
    event SellOrderCompleted(bytes32 indexed sellOrderId, address indexed seller);
    event Sell(address indexed seller, uint256 amount, bytes32 indexed sellOrderId);
    event SellOrderCreated(bytes32 indexed sellOrderId, uint256 amount, uint256 price, address indexed seller);
    event DetailedPurchase(address indexed buyer, uint256 amount, uint256 totalCost, bytes32[] completedOrders);


    struct SellOrder {
        bytes32 sellOrderId;
        uint256 amount;
        uint256 price;
        bytes32 previous;
        bytes32 next;
        address seller;
        bool canceled;
        bool bought;
    }

    modifier onlyLifeProtocolAffiliate() {
        require(msg.sender == LifeProtocolAffiliate, "only call by referral contract!");
        _;
    }  

    constructor(address _deployer, address _token, address treasuryProtocol ,address teamAddress)  Ownable(_deployer) {
        minTradeAmount = 1 *(10**18);
        maxTradeAmount = 5000 *(10**18);
        currentPrice = 1e18;

        lifeToken = new LifeToken("LIFE", "LIFE", _deployer, address(this),treasuryProtocol,teamAddress);
        UsdtToken = IERC20(_token) ;

        uint256 remainingAmount = lifeToken.balanceOf(address(this));
        remainingSupply = remainingAmount;
        queueSupply = 0;
    }

    function buy(uint256 lifeTokenAmount) external nonReentrant {
        uint256 totalUsdtCost = calculateTotalCost(lifeTokenAmount);
        require(totalUsdtCost >= minTradeAmount && totalUsdtCost <= maxTradeAmount, "Invalid trade amount");

        buyBackReserve = buyBackReserve.add(totalUsdtCost);

        require(UsdtToken.transferFrom(msg.sender,address(this),totalUsdtCost),"usdt transfer failed!");

        uint256 contractTokenBalance = lifeToken.balanceOf(address(this));
        uint256 availableSupply = contractTokenBalance > queueSupply ? contractTokenBalance.sub(queueSupply) : 0;
        uint256 deficit = 0;

        if (availableSupply >= lifeTokenAmount) {
            buyFromSupply(msg.sender, lifeTokenAmount);
        } else {
            deficit = lifeTokenAmount.sub(availableSupply);
            if (availableSupply > 0) {
                buyFromSupply(msg.sender, availableSupply);
            }
            buyFromSellOrders(msg.sender, deficit);
        }
        buyBack();
        handleRatio(totalUsdtCost);
    }

    function referredBuy(address _user, uint256 _usdtAmount, uint256 _usdtDiscount) public  onlyLifeProtocolAffiliate {
        require(_usdtAmount > 0, "Incorrect usdt amount sent");
        uint256 totalUsdtAmount = _usdtAmount.add(_usdtDiscount);
        uint256 totalLifeTokenAmount = calculateTokenAmount(totalUsdtAmount);
        require(totalUsdtAmount >= minTradeAmount && totalUsdtAmount <= maxTradeAmount, "Invalid USDT trade amount");
        buyBackReserve = buyBackReserve.add(_usdtAmount);

        uint256 contractTokenBalance = lifeToken.balanceOf(address(this));
        uint256 availableSupply = contractTokenBalance > queueSupply ? contractTokenBalance.sub(queueSupply) : 0;
        uint256 deficit = 0;

        if (availableSupply >= totalLifeTokenAmount) {
            buyFromSupply(_user, totalLifeTokenAmount);
        } else {
            deficit = totalLifeTokenAmount.sub(availableSupply);

            if (availableSupply > 0) {
                buyFromSupply(_user, availableSupply);
            }
            buyFromSellOrders(_user, deficit);
        }
        buyBack();
        handleRatio(totalUsdtAmount);
    }

    function sell(uint256 amount) external nonReentrant {
        require(lifeToken.balanceOf(msg.sender) >= amount, "Insufficient balance");

        bytes32 sellOrderId = generateSellOrderId();
        bytes32 previousOrderId = currentSellOrderId;

        uint256 sellPrice = currentPrice.mul(90).div(100);
        uint256 requiredUSDT = sellPrice.mul(amount).div(1e18);
        require(requiredUSDT >= minTradeAmount && requiredUSDT <= maxTradeAmount, "Invalid  Usdt trade amount");

        sellOrders[sellOrderId] = SellOrder({
            sellOrderId: sellOrderId,
            amount: amount,
            price: sellPrice,
            previous: previousOrderId,
            next: bytes32(0),
            seller: msg.sender,
            canceled: false,
            bought: false
        });

        if (UsdtToken.balanceOf(address(this)) >= requiredUSDT) {

            lifeToken.transferFrom(msg.sender, address(this), amount);
            remainingSupply = remainingSupply.add(amount);
            buyBackReserve = buyBackReserve.sub(requiredUSDT);
            require(UsdtToken.transfer(msg.sender,requiredUSDT),"usdt transfer failed!");
            sellOrders[sellOrderId].bought = true;
            if (sellOrders[previousOrderId].next == sellOrderId) {
                currentSellOrderId = sellOrders[sellOrderId].next;
            }

            emit SellOrderCompleted(sellOrderId, msg.sender);
        } else {

            lifeToken.transferFrom(msg.sender, address(this), amount);
            queueSupply = queueSupply.add(amount);

            if (currentSellOrderId != bytes32(0)) {
                sellOrders[currentSellOrderId].next = sellOrderId;
            }

            if (currentSellOrderId == bytes32(0)) {
                currentSellOrderId = sellOrderId;
            }

            sellOrderCounter = sellOrderCounter.add(1);

            sellerOrders[msg.sender].push(sellOrderId);

            emit SellOrderCreated(sellOrderId, uint256(amount), uint256(sellPrice), msg.sender);
        }
        buyBack();
        
    }

    function buyBack() internal {
        if (currentSellOrderId != bytes32(0) && buyBackReserve > sellOrders[currentSellOrderId].amount.mul(sellOrders[currentSellOrderId].price).div(1e18)) {
            resolveBuyback();
        }
    }

    function resolveBuyback() internal {
        SellOrder storage order = sellOrders[currentSellOrderId];
        uint256 amount = order.amount;
        uint256 price = order.price;

        require(buyBackReserve >= amount.mul(price).div(1e18), "Insufficient buyBack reserve");
        buyBackReserve = buyBackReserve.sub(amount.mul(price).div(1e18));
        lifeToken.transferFrom(order.seller, address(this), amount);
        queueSupply = queueSupply.sub(amount);
        UsdtToken.transfer(order.seller,amount.mul(price).div(1e18));
        order.bought = true;
        currentSellOrderId = order.next;

        emit BuyBackExecuted(amount, price);
        emit SellOrderCompleted(order.sellOrderId, order.seller);
    }

    function buyFromSupply(address user, uint256 amount) internal {
        require(lifeToken.balanceOf(address(this)) >= amount, "Reserve does not have enough tokens");

        remainingSupply = remainingSupply.sub(amount);
        lifeToken.transfer(user, amount);
        uint256 price = amount.mul(currentPrice).div(1e18);

        emit Buy(user, amount, price);
    }

    function buyFromSellOrders(address user,uint256 amount) internal {
        uint256 remainingAmount = amount;
        bytes32[] memory completedOrders = new bytes32[](sellOrderCounter);
        uint256 completedOrderCount = 0;

        while (remainingAmount > 0 && currentSellOrderId != bytes32(0)) {
            SellOrder storage order = sellOrders[currentSellOrderId];
            require(!order.canceled, "Sell order is canceled");

            uint256 orderAmount = order.amount;

            if (orderAmount == 0) {
                currentSellOrderId = order.next;
                continue;
            }

            if (remainingAmount >= orderAmount) {
                remainingAmount = remainingAmount.sub(orderAmount);
                queueSupply = queueSupply.sub(orderAmount);
                uint256 USDTToTransfer = orderAmount.mul(order.price).div(1e18);
                UsdtToken.transfer(order.seller,USDTToTransfer);
                buyBackReserve = buyBackReserve.sub(USDTToTransfer);

                lifeToken.transfer(user, orderAmount);

                order.bought = true;
                completedOrders[completedOrderCount] = currentSellOrderId;
                completedOrderCount++;

                emit SellOrderCompleted(currentSellOrderId, order.seller);
                bytes32 nextOrderId = order.next;
                delete sellOrders[currentSellOrderId];
                currentSellOrderId = nextOrderId;
                sellOrderCounter--;
            } else {
                order.amount = order.amount.sub(remainingAmount);
                queueSupply = queueSupply.sub(remainingAmount);
                uint256 USDTToTransfer = remainingAmount.mul(order.price).div(1e18);
                UsdtToken.transfer(order.seller,USDTToTransfer);
                buyBackReserve = buyBackReserve.sub(USDTToTransfer);
                lifeToken.transfer(user, remainingAmount);

                remainingAmount = 0;
            }
        }

        require(remainingAmount == 0, "Not enough tokens in sell orders to fulfill the purchase");
        emit DetailedPurchase(user, amount, amount.mul(currentPrice).div(1e18), completedOrders);
    }

    function calculatePriceIncrease(uint256 transactionValue) public view returns (uint256) {
        uint256 priceIncrease;

        if (currentPrice <= 10 * 1e18) { 
            priceIncrease = transactionValue.mul(1).div(100000);
        } else if (currentPrice <= 50 * 1e18) {
            priceIncrease = transactionValue.mul(2).div(1000000);
        } else if (currentPrice <= 100 * 1e18) {
            priceIncrease = transactionValue.mul(2).div(10000000); 
        } else {
            priceIncrease = transactionValue.div(21000000);
        }

        return priceIncrease;
    }

    function cancelSellOrder(bytes32 sellOrderId) public nonReentrant {
        SellOrder storage order = sellOrders[sellOrderId];
        require(order.seller == msg.sender, "Only the seller can cancel the order");
        require(!order.bought, "Sell order has already been bought");
        require(!order.canceled, "Sell order is already canceled");

        if (order.previous != bytes32(0)) {
            sellOrders[order.previous].next = order.next;
        }
        if (order.next != bytes32(0)) {
            sellOrders[order.next].previous = order.previous;
        }
        if (currentSellOrderId == sellOrderId) {
            currentSellOrderId = order.next;
        }

        lifeToken.transfer(msg.sender, order.amount);
        queueSupply = queueSupply.sub(order.amount);
        order.canceled = true;

        emit SellOrderCancelled(sellOrderId);
    }

    function contributeToBuyBackReserve(uint256 amount) external nonReentrant onlyLifeProtocolAffiliate {  
        require(amount > 0, "Must send a positive amount");
        buyBackReserve = buyBackReserve.add(amount);
        emit BuyBackReserveContribution(msg.sender, amount);
    }

    function contributeToBuyBackReserveFromLife(uint256 amount) external  {
        require(amount > 0, "Must send a positive amount");
        buyBackReserve = buyBackReserve.add(amount);
        require(UsdtToken.transferFrom(msg.sender, address(this), amount),"Usdt transfer failed!");
        handle_Ratio();
        emit BuyBackReserveContribution(msg.sender, amount);
    }

    function handle_Ratio() internal {
        uint256 circulatingSupply = lifeToken.totalSupply().sub(lifeToken.balanceOf(address(this)));
        uint256 circulatingSupplyValue = (circulatingSupply.mul(currentPrice)).div(1e18);

        if (buyBackReserve > circulatingSupplyValue) {
            uint256 newPrice = (buyBackReserve.mul(1e18)).div(circulatingSupply);
            currentPrice = newPrice;
            emit PriceAdjusted(newPrice);
        }
    }

    function handleRatio(uint256 _amount) internal {
        uint256 circulatingSupply = lifeToken.totalSupply().sub(lifeToken.balanceOf(address(this)));
        uint256 circulatingSupplyValue = (circulatingSupply.mul(currentPrice)).div(1e18);

        if (buyBackReserve > circulatingSupplyValue) {
            uint256 newPrice = (buyBackReserve.mul(1e18)).div(circulatingSupply);
            currentPrice = newPrice;
            emit PriceAdjusted(newPrice);
        }else{
            uint256 priceIncrease = calculatePriceIncrease(_amount);
            currentPrice = currentPrice.add(priceIncrease);
        }
    }

    function generateSellOrderId() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, msg.sender, sellOrderCounter));
    }

    function updateMinMaxTradeAmount(uint256 _newMinTradeAmount, uint256 _newMaxTradeAmount) external onlyOwner {
        minTradeAmount = _newMinTradeAmount;
        maxTradeAmount = _newMaxTradeAmount;
    }

    function setLifeProtocolAffiliate(address _contract) external onlyOwner{
        LifeProtocolAffiliate = _contract;
    }

    function getSellOrdersBySeller(address _seller) external view returns (bytes32[] memory) {
        return sellerOrders[_seller];
    }

    function getCurrentPrice() external view returns (uint256) {
        return currentPrice;
    }

    function getNextOrderId(bytes32 sellOrderId) external view returns (bytes32) {
        return sellOrders[sellOrderId].next;
    }

    function getPreviousOrderId(bytes32 sellOrderId) external view returns (bytes32) {
        return sellOrders[sellOrderId].previous;
    }

    function getFirstSellOrderId() external view returns (bytes32) {
        return currentSellOrderId;
    }

    function getLastSellOrderId() external view returns (bytes32) {
        return bytes32(sellOrderCounter);
    }

    function getSellerAddress(bytes32 sellOrderId) external view returns (address) {
        return sellOrders[sellOrderId].seller;
    }

    function getSellOrderDetails(bytes32 sellOrderId) external view returns (uint256 amount, uint256 price, bytes32 previous, bytes32 next, address seller, bool canceled) {
        SellOrder storage order = sellOrders[sellOrderId];
        return (order.amount, order.price, order.previous, order.next, order.seller, order.canceled);
    }

    function calculateTotalCost(uint256 _lifeAmount) public view returns (uint256) {
        return (_lifeAmount.mul(currentPrice)).div(1e18);
    }

    function calculateTokenAmount(uint256 _usdtAmount) public view returns (uint256) {
        return (_usdtAmount.mul(1e18)).div(currentPrice);
    }

    function getSupplyInfo() external view returns (uint256, uint256) {
        return (remainingSupply,queueSupply);
    }

    function checkUsdtBalance() public view returns(uint256){
        uint256 balance = UsdtToken.balanceOf(address(this));
        if(balance > 0){
            return balance ;
        }
        else{
            return 0 ;
        }
    }

    function getTradeAmount() public view returns(uint256, uint256){
        return (minTradeAmount,maxTradeAmount);
    }

    function checkLifeBalance() public view returns(uint256){
         uint256 balance = lifeToken.balanceOf(address(this));
        if(balance > 0){
            return balance ;
        }
        else{
            return 0 ; 
        }
    }

}