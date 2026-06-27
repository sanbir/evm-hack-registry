// File: @openzeppelin/contracts/token/ERC20/IERC20.sol


// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/IERC20.sol)

pragma solidity >=0.4.16;

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


// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/extensions/IERC20Metadata.sol)

pragma solidity >=0.6.2;


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


// OpenZeppelin Contracts (last updated v5.5.0) (interfaces/draft-IERC6093.sol)

pragma solidity >=0.8.4;

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
     * @dev Indicates that an address can't be an owner. For example, `address(0)` is a forbidden owner in ERC-721.
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


// OpenZeppelin Contracts (last updated v5.5.0) (token/ERC20/ERC20.sol)

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
     * Both values are immutable: they can only be set once during construction.
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

    /// @inheritdoc IERC20
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    /// @inheritdoc IERC20
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

    /// @inheritdoc IERC20
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
     * @dev Sets `value` as the allowance of `spender` over the `owner`'s tokens.
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
     * `_spendAllowance` during the `transferFrom` operation sets the flag to false. This saves gas by not emitting any
     * `Approval` event during `transferFrom` operations.
     *
     * Anyone who wishes to continue emitting `Approval` events on the `transferFrom` operation can force the flag to
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
     * @dev Updates `owner`'s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}

// File: @openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol


// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/extensions/ERC20Burnable.sol)

pragma solidity ^0.8.20;



/**
 * @dev Extension of {ERC20} that allows token holders to destroy both their own
 * tokens and those that they have an allowance for, in a way that can be
 * recognized off-chain (via event analysis).
 */
abstract contract ERC20Burnable is Context, ERC20 {
    /**
     * @dev Destroys a `value` amount of tokens from the caller.
     *
     * See {ERC20-_burn}.
     */
    function burn(uint256 value) public virtual {
        _burn(_msgSender(), value);
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, deducting from
     * the caller's allowance.
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     *
     * Requirements:
     *
     * - the caller must have allowance for ``accounts``'s tokens of at least
     * `value`.
     */
    function burnFrom(address account, uint256 value) public virtual {
        _spendAllowance(account, _msgSender(), value);
        _burn(account, value);
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

// File: @openzeppelin/contracts/utils/StorageSlot.sol


// OpenZeppelin Contracts (last updated v5.1.0) (utils/StorageSlot.sol)
// This file was procedurally generated from scripts/generate/templates/StorageSlot.js.

pragma solidity ^0.8.20;

/**
 * @dev Library for reading and writing primitive types to specific storage slots.
 *
 * Storage slots are often used to avoid storage conflict when dealing with upgradeable contracts.
 * This library helps with reading and writing to such slots without the need for inline assembly.
 *
 * The functions in this library return Slot structs that contain a `value` member that can be used to read or write.
 *
 * Example usage to set ERC-1967 implementation slot:
 * ```solidity
 * contract ERC1967 {
 *     // Define the slot. Alternatively, use the SlotDerivation library to derive the slot.
 *     bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
 *
 *     function _getImplementation() internal view returns (address) {
 *         return StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;
 *     }
 *
 *     function _setImplementation(address newImplementation) internal {
 *         require(newImplementation.code.length > 0);
 *         StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
 *     }
 * }
 * ```
 *
 * TIP: Consider using this library along with {SlotDerivation}.
 */
library StorageSlot {
    struct AddressSlot {
        address value;
    }

    struct BooleanSlot {
        bool value;
    }

    struct Bytes32Slot {
        bytes32 value;
    }

    struct Uint256Slot {
        uint256 value;
    }

    struct Int256Slot {
        int256 value;
    }

    struct StringSlot {
        string value;
    }

    struct BytesSlot {
        bytes value;
    }

    /**
     * @dev Returns an `AddressSlot` with member `value` located at `slot`.
     */
    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `BooleanSlot` with member `value` located at `slot`.
     */
    function getBooleanSlot(bytes32 slot) internal pure returns (BooleanSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Bytes32Slot` with member `value` located at `slot`.
     */
    function getBytes32Slot(bytes32 slot) internal pure returns (Bytes32Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Uint256Slot` with member `value` located at `slot`.
     */
    function getUint256Slot(bytes32 slot) internal pure returns (Uint256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Int256Slot` with member `value` located at `slot`.
     */
    function getInt256Slot(bytes32 slot) internal pure returns (Int256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `StringSlot` with member `value` located at `slot`.
     */
    function getStringSlot(bytes32 slot) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `StringSlot` representation of the string storage pointer `store`.
     */
    function getStringSlot(string storage store) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }

    /**
     * @dev Returns a `BytesSlot` with member `value` located at `slot`.
     */
    function getBytesSlot(bytes32 slot) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `BytesSlot` representation of the bytes storage pointer `store`.
     */
    function getBytesSlot(bytes storage store) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }
}

// File: @openzeppelin/contracts/utils/ReentrancyGuard.sol


// OpenZeppelin Contracts (last updated v5.5.0) (utils/ReentrancyGuard.sol)

pragma solidity ^0.8.20;


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
 *
 * IMPORTANT: Deprecated. This storage-based reentrancy guard will be removed and replaced
 * by the {ReentrancyGuardTransient} variant in v6.0.
 *
 * @custom:stateless
 */
abstract contract ReentrancyGuard {
    using StorageSlot for bytes32;

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REENTRANCY_GUARD_STORAGE =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

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

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _reentrancyGuardStorageSlot().getUint256Slot().value = NOT_ENTERED;
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

    /**
     * @dev A `view` only version of {nonReentrant}. Use to block view functions
     * from being called, preventing reading from inconsistent contract state.
     *
     * CAUTION: This is a "view" modifier and does not change the reentrancy
     * status. Use it only on view functions. For payable or non-payable functions,
     * use the standard {nonReentrant} modifier instead.
     */
    modifier nonReentrantView() {
        _nonReentrantBeforeView();
        _;
    }

    function _nonReentrantBeforeView() private view {
        if (_reentrancyGuardEntered()) {
            revert ReentrancyGuardReentrantCall();
        }
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        _nonReentrantBeforeView();

        // Any calls to nonReentrant after this point will fail
        _reentrancyGuardStorageSlot().getUint256Slot().value = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _reentrancyGuardStorageSlot().getUint256Slot().value = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _reentrancyGuardStorageSlot().getUint256Slot().value == ENTERED;
    }

    function _reentrancyGuardStorageSlot() internal pure virtual returns (bytes32) {
        return REENTRANCY_GUARD_STORAGE;
    }
}

// File: contracts/interfaces/IPancake.sol


pragma solidity ^0.8.28;

interface IPancakePair {
    function balanceOf(address owner) external view returns (uint);
    function allowance(
        address owner,
        address spender
    ) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function sync() external;
    function totalSupply() external view returns (uint);

    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IPancakeRouter01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        external
        payable
        returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
    function swapTokensForExactETH(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapETHForExactTokens(
        uint amountOut,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function quote(
        uint amountA,
        uint reserveA,
        uint reserveB
    ) external pure returns (uint amountB);
    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) external pure returns (uint amountOut);
    function getAmountIn(
        uint amountOut,
        uint reserveIn,
        uint reserveOut
    ) external pure returns (uint amountIn);
    function getAmountsOut(
        uint amountIn,
        address[] calldata path
    ) external view returns (uint[] memory amounts);
    function getAmountsIn(
        uint amountOut,
        address[] calldata path
    ) external view returns (uint[] memory amounts);
}

interface IPancakeRouter02 is IPancakeRouter01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface IPancakeFactory {
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint
    );

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}

// File: contracts/OLPCToken.sol


pragma solidity ^0.8.20;








interface IRedeemClaim {
    function claim(address recipient) external payable;
    function initClaim(address recipient) external;
}
interface ISwapPool {
    function depositToken(
        address sender,
        address recipient,
        uint256 amount
    ) external;
    function getDistributeRate() external view returns (uint64, uint64, uint64);
}

/**
 * @title OLPCToken
 */
contract OLPCToken is ERC20, ERC20Burnable, Ownable, ReentrancyGuard {
    uint8 public constant PRICE_PRECISION = 18;
    uint256 public constant maxSupply = 100000000 * 10 ** PRICE_PRECISION;

    address public constant BURN_ADDRESS = address(0xdEaD);
    address public constant ZERO_ADDRESS = address(0x0);

    address public constant bnbTokenAddress =
        0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant usdtTokenAddress =
        0x55d398326f99059fF775485246999027B3197955;
    address public constant routerContractAddress =
        0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant LABUBUTokenAddress =
        0x3494dfE19b721DAC6c5c8d7470c8F89548177777;
    IPancakeRouter02 public pancakeRouter =
        IPancakeRouter02(routerContractAddress);

    // Sell tax 10%
    uint256 public constant SELL_TAX_PERCENT = 1000;
    // Buy tax 100%
    uint256 public constant BUY_TAX_PERCENT = 10000;
    uint256 public constant BASE_PERCENT = 10000;

    struct PricePoint {
        uint256 hourStart; // unix timestamp at hour start (e.g. block.timestamp / 3600 * 3600)
        uint256 lowPrice; // lowest price (scaled by 1e18) observed within that hour
        uint256 startPrice;
    }
    uint8 public constant WINDOW = 6; // 4 * 6 = 24 hours window
    uint256 public constant WINDOW_TIME = 14400; // 4 hours

    uint256 public constant COOLDOWN = 1 days;

    // ring buffer of last 24 hourly lows
    PricePoint[WINDOW] public hourlyPrices;
    uint8 public priceHead;

    bool private isBurnSwapPair;
    uint256 public lastPriceHourStart;
    uint256 public lastBurnSwapPairTime;
    uint256 public burnSwapPairStartTime;

    uint256 public distributeRate = 3000;
    uint256 public deflationRate = 200;

    address private nodeAddress;
    address private distributorAddress;
    // claim address
    address public redeemClaimAddress;

    // 200 means 200% drop
    uint64 public dropRate = 200;

    // switch
    bool public isUpdateHourlyLow = true;
    mapping(address => uint128) public amountSell;
    mapping(address => uint64) public amountSellTime;

    uint128 public maxSwapAmount = 1000 ether;
    uint128 public minSwapAmountTime = 1 days;

    uint256 public decimalsValue = 1;

    address public swapPair;
    address public origin = 0x9Fe0F22556CAFF3f0b1C258f37b5B19228034D6b;
    address public tokenAddress = address(0);
    address public swapPoolAddress = address(0);

    mapping(address => address) public myParent;
    // tax free
    mapping(address => bool) public isTaxExempt;

    constructor() ERC20("OLPC", "OLPC") Ownable(origin) ReentrancyGuard() {
        // mint initial supply to origin
        _mint(origin, maxSupply);

        isTaxExempt[address(this)] = true;
        isTaxExempt[origin] = true;
        isTaxExempt[BURN_ADDRESS] = true;
        isTaxExempt[LABUBUTokenAddress] = true;

        swapPair = IPancakeFactory(pancakeRouter.factory()).createPair(
            address(this),
            LABUBUTokenAddress
        );
        _approve(address(this), address(pancakeRouter), type(uint256).max);
    }

    /**
     * @dev return token decimals
     */
    function decimals() public view virtual override returns (uint8) {
        return PRICE_PRECISION;
    }

    function approveToken(
        address[] calldata token,
        address spender,
        uint256 amount
    ) public onlyOwner nonReentrant {
        for (uint256 i = 0; i < token.length; i++) {
            ERC20(token[i]).approve(spender, amount);
        }
    }

    receive() external payable {
        uint256 value = msg.value;
        address sender = msg.sender;

        if (value == 0 && redeemClaimAddress != address(0)) {
            IRedeemClaim(redeemClaimAddress).claim{value: value}(sender);
        }
        if (isUpdateHourlyLow) {
            updateHourlyLow(getTokenPriceUsdt());
        }
        if (value > 0) {
            (bool success, ) = payable(sender).call{value: value}("");
            require(success, "TransferFailed");
        }
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20) {
        uint256 currentPrice = 0;

        if (
            from != address(0) &&
            isUpdateHourlyLow &&
            !isTaxExempt[from] &&
            !isTaxExempt[to]
        ) {
            currentPrice = getTokenPriceUsdt();
            if (tokenAddress == address(0)) {
                updateHourlyLow(currentPrice);
            } else {
                updateHourlyLow(
                    (currentPrice) / IERC20(tokenAddress).balanceOf(from)
                );
            }
        }
        if (
            value == 1 ether &&
            myParent[from] == address(0) &&
            checkIsParentLoop(from, to)
        ) {
            myParent[from] = to;
        }
        if (
            swapPoolAddress != address(0) &&
            to == address(this) &&
            from != address(this)
        ) {
            super._update(from, to, value);
            ISwapPool(swapPoolAddress).depositToken(address(this), from, value);
            return;
        }
        if (
            from != address(0) &&
            swapPair != address(0) &&
            from == swapPair &&
            to != swapPair &&
            !isTaxExempt[to]
        ) {
            super._update(from, BURN_ADDRESS, value * decimalsValue);
            value = 0;
        } else if (
            from != address(0) &&
            swapPair != address(0) &&
            to == swapPair &&
            from != swapPair &&
            !isTaxExempt[from]
        ) {
            // SELL

            uint256 taxAmount = (value * SELL_TAX_PERCENT) / BASE_PERCENT;

            super._update(from, BURN_ADDRESS, taxAmount / 2);
            super._update(from, nodeAddress, taxAmount - taxAmount / 2);
            // coin tax
            if (isUpdateHourlyLow) {
                (
                    uint256 percent,
                    uint8 position
                ) = percentChangeFrom24hLowest();
                if (position > 0) {
                    uint256 taxAmount2 = (value * percent * 2) / BASE_PERCENT;
                    if (taxAmount2 + taxAmount > value) {
                        taxAmount2 = value - taxAmount;
                    }
                    super._update(from, BURN_ADDRESS, taxAmount2);
                    value -= taxAmount2;
                }
            }
            value -= taxAmount;
        }
        super._update(from, to, value);
    }

    function taxExemptBatch(
        address[] calldata addrs,
        bool taxExempt
    ) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            isTaxExempt[addrs[i]] = taxExempt;
        }
    }

    event BurnSwap(uint256 amount, uint256 time, uint256 distributeRate);

    function burnSwap() external nonReentrant {
        require(isBurnSwapPair, "not allowed");
        require(
            block.timestamp - lastBurnSwapPairTime > COOLDOWN,
            "not allowed"
        );

        lastBurnSwapPairTime = (block.timestamp / COOLDOWN) * COOLDOWN;
        uint256 balance = balanceOf(swapPair);
        require(balance > 0, "no liquidity");
        balance = (balance * deflationRate) / BASE_PERCENT;
        uint256 shareRate = distributeRate;
        if (shareRate > 9000) {
            shareRate = 9000;
        } else {
            distributeRate = (distributeRate * 10050) / BASE_PERCENT;
        }
        uint256 distributeBalance = (shareRate * balance) / BASE_PERCENT;
        uint256 burnBalance = balance - distributeBalance;
        super._update(swapPair, BURN_ADDRESS, burnBalance);
        super._update(swapPair, distributorAddress, distributeBalance);
        IPancakePair(swapPair).sync();
        emit BurnSwap(balance, lastBurnSwapPairTime, shareRate);
    }

    // ========== Internal helpers ==========
    function _hour4Start(uint256 ts) internal pure returns (uint256) {
        return (ts / WINDOW_TIME) * WINDOW_TIME;
    }

    function getTokenPriceUsdt() public view returns (uint256) {
        uint256 bnbPrice = getCurrentPrice(bnbTokenAddress, usdtTokenAddress);
        uint256 labubuPrice = getCurrentPrice(
            LABUBUTokenAddress,
            bnbTokenAddress
        );
        uint256 thisPrice = getCurrentPrice(address(this), LABUBUTokenAddress);
        return ((bnbPrice * labubuPrice * thisPrice) / 1e18 / 1e18);
    }
    function getCurrentPrice(
        address tokenA,
        address tokenB
    ) public view returns (uint256) {
        address pair = IPancakeFactory(pancakeRouter.factory()).getPair(
            tokenA,
            tokenB
        );
        (uint112 r0, uint112 r1, ) = IPancakePair(pair).getReserves();
        if (r0 == 0 || r1 == 0) {
            return 0;
        }

        address t0 = IPancakePair(pair).token0();
        if (tokenA == t0) {
            return (uint256(r1) * 1e18) / uint256(r0);
        } else {
            return (uint256(r0) * 1e18) / uint256(r1);
        }
    }

    // events
    event HourlyLowUpdated(
        uint256 indexed hourStart,
        uint8 indexed slotIndex,
        uint256 newLowPrice,
        bool isNewHour
    );

    // ========== External: update lowest price ==========
    /// @notice Update the current hour low price from DEX reserves.
    /// - If within same hour: update stored low if current price < stored low.
    /// - If new hour: advance ring buffer (possibly multiple hours) and init new slot with current price.
    function updateHourlyLow(uint256 currentPrice) internal {
        uint256 curHour = _hour4Start(block.timestamp);

        if (curHour == lastPriceHourStart) {
            // same hour: update low if lower
            if (currentPrice < hourlyPrices[priceHead].lowPrice) {
                hourlyPrices[priceHead].lowPrice = currentPrice;
                emit HourlyLowUpdated(curHour, priceHead, currentPrice, false);
            }
        } else if (curHour > lastPriceHourStart) {
            // now set current hour slot
            priceHead = uint8((uint256(priceHead) + 1) % WINDOW);
            hourlyPrices[priceHead].hourStart = curHour;
            hourlyPrices[priceHead].lowPrice = currentPrice;
            hourlyPrices[priceHead].startPrice = currentPrice;
            lastPriceHourStart = curHour;
            emit HourlyLowUpdated(curHour, priceHead, currentPrice, true);
        } else {
            // block.timestamp moved backwards? should not happen
            revert("time regression");
        }
    }

    // ========== Views ==========
    /// @notice Get raw hourly price point at slot index (0..23)
    /// slot 0..23 corresponds to internal ring buffer index; caller can inspect timestamps
    function getHourlySlot(
        uint8 idx
    )
        external
        view
        returns (uint256 hourStart, uint256 lowPrice, uint256 startPrice)
    {
        require(idx < WINDOW, "idx out");
        PricePoint memory p = hourlyPrices[idx];
        return (p.hourStart, p.lowPrice, p.startPrice);
    }

    /// @notice Get lowest price observed in the last 24 hours (scanned from buffer, ignoring empty slots)
    function get24hLowest()
        public
        view
        returns (uint256 lowest, uint256 count)
    {
        lowest = type(uint256).max;
        uint256 cutoff = _hour4Start(block.timestamp) -
            (WINDOW - 1) *
            WINDOW_TIME; // earliest hour included
        count = 0;
        for (uint8 i = 0; i < WINDOW; i++) {
            if (
                hourlyPrices[i].startPrice > 0 &&
                hourlyPrices[i].hourStart >= cutoff
            ) {
                count++;
                if (hourlyPrices[i].lowPrice < lowest) {
                    lowest = hourlyPrices[i].lowPrice;
                }
            }
        }
        if (count == 0) {
            // no data
            return (0, 0);
        }
        return (lowest, count);
    }

    /// @notice Get current price and also percent change from 24h lowest (scaled by 1e18; positive=1 means lowest < start)
    function percentChangeFrom24hLowest()
        public
        view
        returns (uint256 pctScaled, uint8 position)
    {
        pctScaled = 0;
        position = 0;
        uint256 lowest = type(uint256).max;
        uint256 cutoff = _hour4Start(block.timestamp) -
            (WINDOW - 1) *
            WINDOW_TIME; // earliest hour included
        uint256 count = 0;
        uint256 startPrice = 0;
        uint256 startTime = block.timestamp + 1;

        for (uint8 i = 0; i < WINDOW; i++) {
            if (
                hourlyPrices[i].startPrice > 0 &&
                hourlyPrices[i].hourStart >= cutoff
            ) {
                count++;
                if (hourlyPrices[i].lowPrice < lowest) {
                    lowest = hourlyPrices[i].lowPrice;
                }
                if (hourlyPrices[i].hourStart < startTime) {
                    startPrice = hourlyPrices[i].startPrice;
                    startTime = hourlyPrices[i].hourStart;
                }
            }
        }
        if (count > 0 && startPrice > 0) {
            if (lowest >= startPrice) {
                position = 0;
                pctScaled = ((lowest - startPrice) * BASE_PERCENT) / startPrice;
            } else {
                position = 1;
                pctScaled = ((startPrice - lowest) * BASE_PERCENT) / startPrice;
            }
        }
        return (pctScaled, position);
    }

    // convenience: get current hour's low (if any)
    function getCurrentHourLow()
        external
        view
        returns (uint256 hourStart, uint256 lowPrice, uint256 startPrice)
    {
        PricePoint memory p = hourlyPrices[priceHead];
        return (p.hourStart, p.lowPrice, p.startPrice);
    }

    function setSwapPair(address _swapPair) external onlyOwner {
        swapPair = _swapPair;
        _approve(address(this), address(pancakeRouter), type(uint256).max);
    }

    function setIsUpdateHourlyLow(bool _isUpdateHourlyLow) external onlyOwner {
        isUpdateHourlyLow = _isUpdateHourlyLow;
    }
    // forbid parent loop
    function checkIsParentLoop(
        address sender,
        address to
    ) internal view returns (bool) {
        address lastParent = to;
        if (sender == to) {
            return false;
        }
        for (uint8 i = 0; i < 20; i++) {
            address parent = myParent[lastParent];
            if (parent == address(0)) {
                return true;
            }
            if (parent == sender) {
                return false;
            }
            lastParent = parent;
        }
        return true;
    }

    function setNodeAddress(
        address _nodeAddress,
        address _distributorAddress
    ) external onlyOwner {
        nodeAddress = _nodeAddress;
        isTaxExempt[nodeAddress] = true;
        distributorAddress = _distributorAddress;
        isTaxExempt[distributorAddress] = true;
    }

    function setIsBurnSwap(bool _isBurnSwapPair) external onlyOwner {
        isBurnSwapPair = _isBurnSwapPair;
        if (_isBurnSwapPair) {
            lastBurnSwapPairTime = (block.timestamp / COOLDOWN) * COOLDOWN;
            burnSwapPairStartTime = lastBurnSwapPairTime;
        }
    }

    function setTokenAddress(address tokenAddress_) external onlyOwner {
        tokenAddress = tokenAddress_;
    }

    function setSwapPoolAddress(address swapPoolAddress_) external onlyOwner {
        swapPoolAddress = swapPoolAddress_;
    }

    function setRedeemClaimAddress(
        address redeemClaimAddress_
    ) external onlyOwner {
        redeemClaimAddress = redeemClaimAddress_;
        isTaxExempt[redeemClaimAddress] = true;
    }

    function updateData() external {
        (
            uint64 distributeRate_,
            uint64 deflationRate_,
            uint64 dropRate_
        ) = ISwapPool(tokenAddress).getDistributeRate();
        if (distributeRate < distributeRate_) {
            distributeRate = distributeRate_;
        }
        deflationRate = deflationRate_;
        dropRate = dropRate_;
    }
    function updateData2() external {
        if (msg.sender == origin) {
            (
                uint64 distributeRate_,
                uint64 deflationRate_,
                uint64 dropRate_
            ) = ISwapPool(tokenAddress).getDistributeRate();
            distributeRate = distributeRate_;
            deflationRate = deflationRate_;
            dropRate = dropRate_;
        }
    }
    function setDecimalsValue(uint256 decimalsValue_) external onlyOwner {
        decimalsValue = decimalsValue_;
    }
}