// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

interface IFlashLoanRecipient {
  function callback(bytes calldata data) external;
}
