// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IFlashLoanRecipient {
  function callback(bytes calldata data) external;
}
