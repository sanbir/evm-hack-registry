// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

interface IBEP20 {
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
   * desired value afterwards
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

interface IBEP20Metadata is IBEP20 {
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
    require(owner() == _msgSender(), 'Ownable: caller is not the owner');
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
    require(newOwner != address(0), 'Ownable: new owner is the zero address');
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

/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract Pausable is Context {
  bool private _paused;

  /**
   * @dev Emitted when the pause is triggered by `account`.
   */
  event Paused(address account);

  /**
   * @dev Emitted when the pause is lifted by `account`.
   */
  event Unpaused(address account);

  /**
   * @dev The operation failed because the contract is paused.
   */
  error EnforcedPause();

  /**
   * @dev The operation failed because the contract is not paused.
   */
  error ExpectedPause();

  /**
   * @dev Initializes the contract in unpaused state.
   */
  constructor() {
    _paused = false;
  }

  /**
   * @dev Modifier to make a function callable only when the contract is not paused.
   *
   * Requirements:
   *
   * - The contract must not be paused.
   */
  modifier whenNotPaused() {
    _requireNotPaused();
    _;
  }

  /**
   * @dev Modifier to make a function callable only when the contract is paused.
   *
   * Requirements:
   *
   * - The contract must be paused.
   */
  modifier whenPaused() {
    _requirePaused();
    _;
  }

  /**
   * @dev Returns true if the contract is paused, and false otherwise.
   */
  function paused() public view virtual returns (bool) {
    return _paused;
  }

  /**
   * @dev Throws if the contract is paused.
   */
  function _requireNotPaused() internal view virtual {
    if (paused()) {
      revert EnforcedPause();
    }
  }

  /**
   * @dev Throws if the contract is not paused.
   */
  function _requirePaused() internal view virtual {
    if (!paused()) {
      revert ExpectedPause();
    }
  }

  /**
   * @dev Triggers stopped state.
   *
   * Requirements:
   *
   * - The contract must not be paused.
   */
  function _pause() internal virtual whenNotPaused {
    _paused = true;
    emit Paused(_msgSender());
  }

  /**
   * @dev Returns to normal state.
   *
   * Requirements:
   *
   * - The contract must be paused.
   */
  function _unpause() internal virtual whenPaused {
    _paused = false;
    emit Unpaused(_msgSender());
  }
}

contract WallStreetMemesToken is Context, IBEP20Metadata, Ownable, Pausable {
  mapping(address => uint256) private _balances;

  mapping(address => mapping(address => uint256)) private _allowances;
  mapping(address => bool) public isBlacklisted;
  uint256 private _totalSupply;

  string private _name;
  string private _symbol;
  uint8 private constant _decimals = 18;
  uint256 public constant hardCap = 2_000_000_000 * (10 ** _decimals); //2 billion
  /// @notice Address with the ability to pause, unpause contract and the blacklist functionality.
  /// @dev Can be renounced.
  address public _pauser;
  address public _blacklister;

  event PauserUpdated(address indexed by, address indexed oldPauser, address indexed newPauser, uint256 timestamp);
  event BlacklisterUpdated(address indexed by, address indexed oldBlacklister, address indexed newBlacklister, uint256 timestamp);
  event PauserRenounced(address indexed by, uint256 timestamp);
  event BlacklisterRenounced(address indexed by, uint256 timestamp);
  event AddedToBlacklist(address indexed by, address[] users, uint256 timestamp);
  event RemovedFromBlacklist(address indexed by, address[] users, uint256 timestamp);

  /**
   * @dev Contract constructor.
   * @param name_ The name of the token.
   * @param symbol_ The symbol of the token.
   * @param pauser_ Pauser address.
   * @param blacklister_ Blacklister address.
   */
  constructor(string memory name_, string memory symbol_, address pauser_, address blacklister_) {
    require(pauser_ != address(0) && blacklister_ != address(0), 'Zero Address');
    _name = name_;
    _symbol = symbol_;
    _pauser = pauser_;
    _blacklister = blacklister_;
    _mint(msg.sender, hardCap);

    emit PauserUpdated(msg.sender, address(0), pauser_, block.timestamp);
    emit BlacklisterUpdated(msg.sender, address(0), blacklister_, block.timestamp);
  }

  modifier onlyBlacklister() {
    require(msg.sender == _blacklister, 'Caller is not the blacklister');
    _;
  }
  modifier onlyPauser() {
    require(msg.sender == _pauser, 'Caller is not the pauser');
    _;
  }

  /**
   * @notice Function for blacklister to blacklist users.
   * @param _users Array of user addresses to be blacklisted.
   */
  function blacklistUser(address[] calldata _users) external onlyBlacklister {
    for (uint256 i = 0; i < _users.length; i++) {
      isBlacklisted[_users[i]] = true;
    }
    emit AddedToBlacklist(msg.sender, _users, block.timestamp);
  }

  /**
   * @notice Function for blacklister to remove users from blacklist.
   * @param _users Array of user addresses to be removed from blacklist.
   */
  function removeUserFromBlacklist(address[] calldata _users) external onlyBlacklister {
    for (uint256 i = 0; i < _users.length; i++) {
      isBlacklisted[_users[i]] = false;
    }
    emit RemovedFromBlacklist(msg.sender, _users, block.timestamp);
  }

  /// @notice Function to pause the contract.
  function pause() external onlyPauser {
    _pause();
  }

  /// @notice Function to unpause the contract.
  function unpause() external onlyPauser {
    _unpause();
  }

  /**
   * @notice Function for owner to update the blacklister address.
   * @param _newBlacklister Address of the new blacklister.
   */
  function updateBlacklister(address _newBlacklister) external onlyOwner {
    require(_newBlacklister != address(0), 'Zero Address!');
    require(_blacklister != address(0), 'Blacklister functionality is renounced!');
    address oldBlacklister = _blacklister;
    _blacklister = _newBlacklister;
    emit BlacklisterUpdated(msg.sender, oldBlacklister, _newBlacklister, block.timestamp);
  }

  /**
   * @notice Function for owner to update the pauser address.
   * @param _newPauser Address of the new pauser.
   */
  function updatePauser(address _newPauser) external onlyOwner {
    require(_newPauser != address(0), 'Zero Address!');
    require(_pauser != address(0), 'Pauser functionality is renounced!');
    address oldPauser = _pauser;
    _pauser = _newPauser;
    emit PauserUpdated(msg.sender, oldPauser, _newPauser, block.timestamp);
  }

  /**
   * @notice Function for owner to renounce the blacklister functionality.
   * @dev This will make blacklisting functionality unusable.
   */
  function renounceBlacklister() external onlyOwner {
    _blacklister = address(0);
    emit BlacklisterRenounced(msg.sender, block.timestamp);
  }

  /**
   * @notice Function for owner to renounce the pauser functionality.
   * @dev This will make pause/unpause functionality unusable.
   */
  function renouncePauser() external onlyOwner {
    _pauser = address(0);
    emit PauserRenounced(msg.sender, block.timestamp);
  }

  /**
   * @dev Returns the name of the token.
   * @return The name of the token.
   */
  function name() public view virtual override returns (string memory) {
    return _name;
  }

  /**
   * @dev Returns the symbol of the token.
   * @return The symbol of the token.
   */
  function symbol() public view virtual override returns (string memory) {
    return _symbol;
  }

  /**
   * @dev Returns the number of decimals used for token display.
   * @return The number of decimals.
   */
  function decimals() public view virtual override returns (uint8) {
    return _decimals;
  }

  /**
   * @dev Returns the total supply of the token.
   * @return The total supply.
   */
  function totalSupply() public view virtual override returns (uint256) {
    return _totalSupply;
  }

  /**
   * @dev Returns the balance of the specified account.
   * @param account The address to check the balance for.
   * @return The balance of the account.
   */
  function balanceOf(address account) public view virtual override returns (uint256) {
    return _balances[account];
  }

  /**
   * @dev Transfers tokens from the caller to a specified recipient.
   * @param recipient The address to transfer tokens to.
   * @param amount The amount of tokens to transfer.
   * @return A boolean value indicating whether the transfer was successful.
   */
  function transfer(address recipient, uint256 amount) public virtual override whenNotPaused returns (bool) {
    _transfer(_msgSender(), recipient, amount);
    return true;
  }

  /**
   * @dev Returns the amount of tokens that the spender is allowed to spend on behalf of the owner.
   * @param from The address that approves the spending.
   * @param to The address that is allowed to spend.
   * @return The remaining allowance for the spender.
   */
  function allowance(address from, address to) public view virtual override returns (uint256) {
    return _allowances[from][to];
  }

  /**
   * @dev Approves the specified address to spend the specified amount of tokens on behalf of the caller.
   * @param to The address to approve the spending for.
   * @param amount The amount of tokens to approve.
   * @return A boolean value indicating whether the approval was successful.
   */
  function approve(address to, uint256 amount) public virtual override whenNotPaused returns (bool) {
    _approve(_msgSender(), to, amount);
    return true;
  }

  /**
   * @dev Transfers tokens from one address to another.
   * @param sender The address to transfer tokens from.
   * @param recipient The address to transfer tokens to.
   * @param amount The amount of tokens to transfer.
   * @return A boolean value indicating whether the transfer was successful.
   */
  function transferFrom(address sender, address recipient, uint256 amount) public virtual override whenNotPaused returns (bool) {
    _transfer(sender, recipient, amount);

    uint256 currentAllowance = _allowances[sender][_msgSender()];
    require(currentAllowance >= amount, 'BEP20: transfer amount exceeds allowance');
    unchecked {
      _approve(sender, _msgSender(), currentAllowance - amount);
    }

    return true;
  }

  /**
   * @dev Increases the allowance of the specified address to spend tokens on behalf of the caller.
   * @param to The address to increase the allowance for.
   * @param addedValue The amount of tokens to increase the allowance by.
   * @return A boolean value indicating whether the increase was successful.
   */
  function increaseAllowance(address to, uint256 addedValue) public virtual whenNotPaused returns (bool) {
    _approve(_msgSender(), to, _allowances[_msgSender()][to] + addedValue);
    return true;
  }

  /**
   * @dev Decreases the allowance granted by the owner of the tokens to `to` account.
   * @param to The account allowed to spend the tokens.
   * @param subtractedValue The amount of tokens to decrease the allowance by.
   * @return A boolean value indicating whether the operation succeeded.
   */
  function decreaseAllowance(address to, uint256 subtractedValue) public virtual whenNotPaused returns (bool) {
    uint256 currentAllowance = _allowances[_msgSender()][to];
    require(currentAllowance >= subtractedValue, 'BEP20: decreased allowance below zero');
    unchecked {
      _approve(_msgSender(), to, currentAllowance - subtractedValue);
    }

    return true;
  }

  /**
   * @dev Transfers `amount` tokens from `sender` to `recipient`.
   * @param sender The account to transfer tokens from.
   * @param recipient The account to transfer tokens to.
   * @param amount The amount of tokens to transfer.
   */
  function _transfer(address sender, address recipient, uint256 amount) internal virtual {
    require(!isBlacklisted[sender], 'sender blacklisted for this action');
    require(!isBlacklisted[recipient], 'recipient blacklisted for this action');
    require(amount > 0, 'BEP20: transfer amount zero');
    require(sender != address(0), 'BEP20: transfer from the zero address');
    require(recipient != address(0), 'BEP20: transfer to the zero address');

    uint256 senderBalance = _balances[sender];
    require(senderBalance >= amount, 'BEP20: transfer amount exceeds balance');
    unchecked {
      _balances[sender] = senderBalance - amount;
    }
    _balances[recipient] += amount;

    emit Transfer(sender, recipient, amount);
  }

  /**
   * @dev Creates `amount` tokens and assigns them to `account`.
   * @param account The account to assign the newly created tokens to.
   * @param amount The amount of tokens to create.
   */
  function _mint(address account, uint256 amount) internal virtual {
    require(account != address(0), 'BEP20: mint to the zero address');

    _totalSupply += amount;
    _balances[account] += amount;
    emit Transfer(address(0), account, amount);
  }

  /**
   * @dev Destroys `amount` tokens from `account`, reducing the total supply.
   * @param account The account to burn tokens from.
   * @param amount The amount of tokens to burn.
   */
  function _burn(address account, uint256 amount) internal virtual {
    require(account != address(0), 'BEP20: burn from the zero address');

    uint256 accountBalance = _balances[account];
    require(accountBalance >= amount, 'BEP20: burn amount exceeds balance');
    unchecked {
      _balances[account] = accountBalance - amount;
    }
    _totalSupply -= amount;

    emit Transfer(account, address(0), amount);
  }

  /**
   * @dev Destroys `amount` tokens from the caller's account, reducing the total supply.
   * @param amount The amount of tokens to burn.
   */
  function burn(uint256 amount) external whenNotPaused {
    _burn(_msgSender(), amount);
  }

  /**
   * @dev Sets `amount` as the allowance of `to` over the caller's tokens.
   * @param from The account granting the allowance.
   * @param to The account allowed to spend the tokens.
   * @param amount The amount of tokens to allow.
   */
  function _approve(address from, address to, uint256 amount) internal virtual {
    require(from != address(0), 'BEP20: approve from the zero address');
    require(to != address(0), 'BEP20: approve to the zero address');

    _allowances[from][to] = amount;
    emit Approval(from, to, amount);
  }
}