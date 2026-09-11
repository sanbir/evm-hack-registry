// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {VaultV1} from "../vault/VaultV1.sol";

contract TreasuryV1 is OwnableUpgradeable {
  using SafeERC20 for IERC20;

  error TreasuryInvalidAmount(uint256 amount);
  error TreasuryInvalidRecipient(address recipient);
  error TreasuryTransferFailed(address recipient, uint256 amount);

  constructor() {
    _disableInitializers();
  }

  function initialize() public initializer {
    __Ownable_init(_msgSender());
  }

  receive() external payable {}

  fallback() external payable {}

  /**
   * @notice Transfer ETH to recipient.
   * @param recipient Recipient.
   * @param amount Transfer amount.
   */
  function transferETH(address payable recipient, uint256 amount) external onlyOwner returns (bool) {
    if (amount == 0) revert TreasuryInvalidAmount(amount);
    if (recipient == address(0)) revert TreasuryInvalidRecipient(recipient);

    (bool sent, ) = recipient.call{value: amount}("");
    if (!sent) revert TreasuryTransferFailed(recipient, amount);

    return true;
  }

  /**
   * @notice Transfer target token to recipient.
   * @param token Target token.
   * @param recipient Recipient.
   * @param amount Transfer amount.
   */
  function transfer(address token, address recipient, uint256 amount) external onlyOwner returns (bool) {
    if (amount == 0) revert TreasuryInvalidAmount(amount);
    if (recipient == address(0)) revert TreasuryInvalidRecipient(recipient);

    IERC20(token).safeTransfer(recipient, amount);

    return true;
  }

  /**
   * @notice Approve target token to recipient.
   * @param token Target token.
   * @param recipient Recipient.
   * @param amount Approve amount.
   */
  function approve(address token, address recipient, uint256 amount) external onlyOwner returns (bool) {
    IERC20(token).forceApprove(recipient, amount);

    return true;
  }

  /**
   * @notice Call withdraw from spender.
   * @param spender Target contract.
   */
  function withdrawFrom(address payable spender) external onlyOwner {
    VaultV1(spender).withdraw();
  }
}
