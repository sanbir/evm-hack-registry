// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

interface IAcrossSpokePool {
  function depositV3(
    address depositor,
    address recipient,
    address inputToken,
    address outputToken,
    uint256 inputAmount,
    uint256 outputAmount,
    uint256 destinationChainId,
    address exclusiveRelayer,
    uint32 quoteTimestamp,
    uint32 fillDeadline,
    uint32 exclusivityDeadline,
    bytes memory message
  ) external payable;

  function getCurrentTime() external view returns (uint256);

  function depositQuoteTimeBuffer() external view returns (uint32);

  function fillDeadlineBuffer() external view returns (uint32);
}
