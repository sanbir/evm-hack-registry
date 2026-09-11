// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAcrossSpokePool} from "../interfaces/IAcrossSpokePool.sol";

contract AcrossSpokePoolMock is Ownable, IAcrossSpokePool {
  using SafeERC20 for IERC20;

  error DepositFailed();

  constructor() Ownable(_msgSender()) {}

  function depositV3(
    address,
    address recipient,
    address inputToken,
    address,
    uint256 inputAmount,
    uint256,
    uint256,
    address,
    uint32,
    uint32,
    uint32,
    bytes memory
  ) external payable {
    if (msg.value > 0) {
      (bool sent, ) = recipient.call{value: inputAmount}("");
      if (!sent) revert DepositFailed();
    } else {
      IERC20(inputToken).safeTransferFrom(_msgSender(), address(this), inputAmount);
      IERC20(inputToken).safeTransfer(recipient, inputAmount);
    }
  }

  function getCurrentTime() external view returns (uint256) {
    return block.timestamp;
  }

  function depositQuoteTimeBuffer() external view returns (uint32) {
    return 3600;
  }

  function fillDeadlineBuffer() external view returns (uint32) {
    return 21600;
  }
}
