// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "../types/BtcSerial.sol";

interface IBridge {
  function transmitRequestV2(
    bytes memory _callData,
    address _receiveSide,
    address _oppositeBridge,
    uint256 _chainId
  ) external;

  function transmitRequestBTC(
    address _from,
    bytes calldata _to,
    uint256 _amount,
    BtcSerial _burnSerial
  ) external;

  function receiveRequestV2(
    bytes memory _callData,
    address _receiveSide
  ) external;
}
