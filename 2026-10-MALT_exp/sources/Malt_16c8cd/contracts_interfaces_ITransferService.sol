// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

interface ITransferService {
  function verifyTransfer(
    address,
    address,
    uint256
  )
    external
    view
    returns (
      bool,
      string memory,
      address[2] memory,
      bytes[2] memory
    );

  function verifyTransferAndCall(
    address,
    address,
    uint256
  ) external returns (bool, string memory);

  function numberOfVerifiers() external view returns (uint256);

  function addVerifier(address, address) external;

  function removeVerifier(address) external;

  function proposeNewVerifierManager(address) external;

  function acceptVerifierManagerRole() external;
}
