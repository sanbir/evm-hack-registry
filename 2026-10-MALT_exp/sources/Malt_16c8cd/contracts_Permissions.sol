// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "openzeppelin/access/AccessControl.sol";
import "openzeppelin/token/ERC20/ERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/security/ReentrancyGuard.sol";
import "./interfaces/IRepository.sol";

/// @title Permissions
/// @author 0xScotch <scotch@malt.money>
/// @notice Inherited by almost all Malt contracts to provide access control
contract Permissions is AccessControl, ReentrancyGuard {
  using SafeERC20 for ERC20;

  // Timelock has absolute power across the system
  bytes32 public constant TIMELOCK_ROLE =
    0xf66846415d2bf9eabda9e84793ff9c0ea96d87f50fc41e66aa16469c6a442f05;
  bytes32 public constant ADMIN_ROLE =
    0xa49807205ce4d355092ef5a8a18f56e8913cf4a201fbe287825b095693c21775;
  bytes32 public constant INTERNAL_WHITELIST_ROLE =
    0xe5b3f2579db3f05863c923698749c1a62f6272567d652899a476ff0172381367;

  IRepository public repository;

  function _initialSetup(address _repository) internal {
    require(_repository != address(0), "Perm: Repo setup 0x0");
    _setRoleAdmin(TIMELOCK_ROLE, TIMELOCK_ROLE);
    _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
    _setRoleAdmin(INTERNAL_WHITELIST_ROLE, ADMIN_ROLE);

    repository = IRepository(_repository);
  }

  function grantRoleMultiple(bytes32 role, address[] calldata addresses)
    external
    onlyRoleMalt(getRoleAdmin(role), "Only role admin")
  {
    uint256 length = addresses.length;
    for (uint256 i; i < length; ++i) {
      address account = addresses[i];
      require(account != address(0), "0x0");
      _grantRole(role, account);
    }
  }

  function emergencyWithdrawGAS(address payable destination)
    external
    onlyRoleMalt(TIMELOCK_ROLE, "Must have timelock role")
  {
    require(destination != address(0), "Withdraw: addr(0)");
    // Transfers the entire balance of the Gas token to destination
    (bool success, ) = destination.call{value: address(this).balance}("");
    require(success, "emergencyWithdrawGAS error");
  }

  function emergencyWithdraw(address _token, address destination)
    external
    onlyRoleMalt(TIMELOCK_ROLE, "Must have timelock role")
  {
    require(destination != address(0), "Withdraw: addr(0)");
    // Transfers the entire balance of an ERC20 token at _token to destination
    ERC20 token = ERC20(_token);
    token.safeTransfer(destination, token.balanceOf(address(this)));
  }

  function partialWithdrawGAS(address payable destination, uint256 amount)
    external
    onlyRoleMalt(TIMELOCK_ROLE, "Must have timelock role")
  {
    require(destination != address(0), "Withdraw: addr(0)");
    (bool success, ) = destination.call{value: amount}("");
    require(success, "partialWithdrawGAS error");
  }

  function partialWithdraw(
    address _token,
    address destination,
    uint256 amount
  ) external onlyRoleMalt(TIMELOCK_ROLE, "Must have timelock role") {
    require(destination != address(0), "Withdraw: addr(0)");
    ERC20 token = ERC20(_token);
    token.safeTransfer(destination, amount);
  }

  function hasRole(bytes32 role, address account)
    public
    view
    override
    returns (bool)
  {
    if (super.hasRole(role, account)) {
      return true;
    }

    if (address(repository) == address(0)) {
      return false;
    }
    return repository.hasRole(role, account);
  }

  /*
   * INTERNAL METHODS
   */
  function _transferRole(
    address newAccount,
    address oldAccount,
    bytes32 role
  ) internal {
    _revokeRole(role, oldAccount);
    _grantRole(role, newAccount);
  }

  function _roleSetup(bytes32 role, address account) internal {
    _grantRole(role, account);
    _setRoleAdmin(role, ADMIN_ROLE);
  }

  function _onlyRoleMalt(bytes32 role, string memory reason) internal view {
    require(hasRole(role, _msgSender()), reason);
  }

  // Using internal function calls here reduces compiled bytecode size
  modifier onlyRoleMalt(bytes32 role, string memory reason) {
    _onlyRoleMalt(role, reason);
    _;
  }

  // verifies that the caller is not a contract.
  modifier onlyEOA() {
    require(
      hasRole(INTERNAL_WHITELIST_ROLE, _msgSender()) || msg.sender == tx.origin,
      "Perm: Only EOA"
    );
    _;
  }
}
