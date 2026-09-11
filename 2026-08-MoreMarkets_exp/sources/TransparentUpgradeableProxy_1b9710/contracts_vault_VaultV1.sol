// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract VaultV1 is OwnableUpgradeable, PausableUpgradeable {
  /// @dev Disributed balances.
  mapping(address => uint256) internal _balances;

  /// @dev Distributors addresses.
  mapping(address => bool) internal _distributors;

  /// @dev Total number of distributed tokens.
  uint256 internal _totalDistributed;

  /// @dev Storage gap for future upgrades.
  uint256[10] internal __gap;

  /// @notice Emited if tokens distributed for account.
  event Distribute(address indexed account, uint256 amount);

  /// @notice Emited if distributed tokens have been revoked.
  event Reset(address indexed account);

  /// @notice Emited if distributed tokens have been withdrawal.
  event Withdrawal(address indexed from, address indexed recipient, uint256 amount);

  /// @notice Emited if distributor list changed.
  event ChangeDistributor(address indexed distributor, bool isAdded);

  error VaultWithdrawFailed(address recipient, uint256 amount);
  error VaultInvalidDistributor(address distributor);
  error VaultDistributeOverflow(uint256 balance, uint256 totalDistributed, uint256 amount);

  constructor() {
    _disableInitializers();
  }

  function initialize() public initializer {
    __Ownable_init(_msgSender());
    __Pausable_init();
  }

  receive() external payable {}

  fallback() external payable {}

  /// @return Total number of distributed tokens.
  function totalDistributed() public view returns (uint256) {
    return _totalDistributed;
  }

  /// @param account Target account.
  /// @return Balance distributed tokens of account.
  function balanceOf(address account) public view returns (uint256) {
    return _balances[account];
  }

  /// @notice Add distributor address to distributors list.
  /// @param distributor Target account.
  function addDistributor(address distributor) external onlyOwner {
    _distributors[distributor] = true;
    emit ChangeDistributor(distributor, true);
  }

  /// @notice Remove distributor address to distributors list.
  /// @param distributor Target account.
  function removeDistributor(address distributor) external onlyOwner {
    _distributors[distributor] = false;
    emit ChangeDistributor(distributor, false);
  }

  /// @notice Distribute tokens for account.
  /// @param account Target account.
  /// @param amount Number of tokens distributed.
  function distribute(address account, uint256 amount) external payable {
    address distributor = _msgSender();
    if (!_distributors[distributor]) {
      revert VaultInvalidDistributor(distributor);
    }

    uint256 balance = address(this).balance;
    if (balance < _totalDistributed + amount) {
      revert VaultDistributeOverflow(balance, _totalDistributed, amount);
    }

    _balances[account] += amount;
    _totalDistributed += amount;

    emit Distribute(account, amount);
  }

  function pause() external onlyOwner {
    _pause();
  }

  function unpause() external onlyOwner {
    _unpause();
  }

  /// @dev Withdraw distributed tokens.
  /// @param from Tokens owner address.
  /// @param recipient Tokens recipient address.
  function _withdraw(address from, address recipient) internal {
    uint256 amount = balanceOf(from);
    _balances[from] = 0;
    _totalDistributed -= amount;

    (bool sent, ) = recipient.call{value: amount}("");
    if (!sent) revert VaultWithdrawFailed(recipient, amount);

    emit Withdrawal(from, recipient, amount);
  }

  /// @notice Withdraw distributed tokens of transaction sender.
  function withdraw() external whenNotPaused {
    address recipient = _msgSender();
    _withdraw(recipient, recipient);
  }

  /// @notice Withdraw distributed tokens.
  /// @param from Tokens owner address.
  /// @param recipient Tokens recipient address.
  function withdrawFrom(address from, address recipient) external whenPaused onlyOwner {
    _withdraw(from, recipient);
  }

  /// @notice Revoke distributed tokens.
  /// @param account Targer account address.
  function reset(address account) external whenPaused onlyOwner {
    uint256 balance = _balances[account];
    _balances[account] = 0;
    _totalDistributed -= balance;

    emit Reset(account);
  }

  /// @notice Withdraw not distributed tokens.
  /// @param recipient Tokens recipient address.
  function withdrawCrumbs(address recipient) external onlyOwner {
    uint256 amount = address(this).balance - _totalDistributed;

    (bool sent, ) = recipient.call{value: amount}("");
    if (!sent) revert VaultWithdrawFailed(recipient, amount);

    emit Withdrawal(address(this), recipient, amount);
  }
}
