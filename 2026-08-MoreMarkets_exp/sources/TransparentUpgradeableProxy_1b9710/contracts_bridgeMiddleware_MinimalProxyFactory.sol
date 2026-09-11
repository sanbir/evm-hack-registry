// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Storage} from "../storage/Storage.sol";

contract MinimalProxyFactory is Context {
  address public info;

  event MinimalProxyCreated(address minimalProxy);

  error ProxyInitializationFailed();

  error Forbidden();

  constructor(address _info) {
    info = _info;
  }

  function _getContractCreationCode(address logic) internal pure returns (bytes memory) {
    bytes10 creation = 0x3d602d80600a3d3981f3;
    bytes10 prefix = 0x363d3d373d3d3d363d73;
    bytes20 targetBytes = bytes20(logic);
    bytes15 suffix = 0x5af43d82803e903d91602b57fd5bf3;

    return abi.encodePacked(creation, prefix, targetBytes, suffix);
  }

  /**
   * @notice Calculates proxy contract address for salt.
   * @param salt CREATE2 opcode salt.
   * @param implementation Proxy implementation contract address.
   * @return Proxy contract address.
   */
  function computeAddress(bytes32 salt, address implementation) external view returns (address) {
    return Create2.computeAddress(salt, keccak256(_getContractCreationCode(implementation)), address(this));
  }

  /**
   * @notice Deploy and initialize minimal proxy contract for salt.
   * @param salt CREATE2 opcode salt.
   * @param implementation Proxy implementation contract address.
   * @param data Initialize method data.
   * @return Proxy contract address.
   */
  function deploy(bytes32 salt, address implementation, bytes memory data) external returns (address) {
    bool isCallAllowed = Storage(info).getBool(
      keccak256(abi.encodePacked("EH:MinimalProxyFactory:Deployer:", _msgSender()))
    );
    if (!isCallAllowed) revert Forbidden();

    address minimalProxy = Create2.deploy(0, salt, _getContractCreationCode(implementation));
    if (data.length > 0) {
      // solhint-disable-next-line avoid-low-level-calls
      (bool success, ) = minimalProxy.call(data);
      if (!success) revert ProxyInitializationFailed();
    }

    emit MinimalProxyCreated(minimalProxy);

    return minimalProxy;
  }
}
