// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "./Multiownable.sol";

contract GovernorMultisig is Multiownable {
  /// @notice The maximum number of actions that can be included in a transaction
  uint256 public constant MAX_OPERATIONS = 10; // 10 actions

  /**
   * @notice Execute target transactions with multisig.
   * @param targets Target addresses for transaction calls
   * @param values Eth values for transaction calls
   * @param signatures Function signatures for transaction calls
   * @param calldatas Calldatas for transaction calls
   */
  function executeTransaction(
    address[] memory targets,
    uint256[] memory values,
    string[] memory signatures,
    bytes[] memory calldatas
  ) external onlyManyOwners {
    require(
      targets.length == values.length && targets.length == signatures.length && targets.length == calldatas.length,
      "GovernorMultisig::executeTransaction: function information parity mismatch"
    );
    require(targets.length != 0, "GovernorMultisig::executeTransaction: must provide actions");
    require(targets.length <= MAX_OPERATIONS, "GovernorMultisig::executeTransaction: too many actions");

    for (uint8 i = 0; i < targets.length; i++) {
      bytes memory callData = bytes(signatures[i]).length == 0
        ? calldatas[i]
        : abi.encodePacked(bytes4(keccak256(bytes(signatures[i]))), calldatas[i]);

      // solhint-disable-next-line avoid-low-level-calls
      (bool success, ) = targets[i].call{value: values[i]}(callData);
      require(success, "GovernorMultisig::executeTransaction: transaction execution reverted");
    }
  }
}
