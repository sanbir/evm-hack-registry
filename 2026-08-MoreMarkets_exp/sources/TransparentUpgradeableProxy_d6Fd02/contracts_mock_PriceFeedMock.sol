// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {IPriceFeed} from "../interfaces/IPriceFeed.sol";

contract PriceFeedMock is IPriceFeed {
  uint8 public decimals;

  struct RoundData {
    uint80 roundId;
    int256 answer;
    uint256 startedAt;
    uint256 updatedAt;
    uint80 answeredInRound;
  }

  uint256 public latestRound;

  mapping(uint256 => RoundData) internal _rounds;

  constructor(uint8 _decimals) {
    decimals = _decimals;
  }

  function setRound(int256 answer) external {
    latestRound++;
    _rounds[latestRound] = RoundData({roundId: 0, answer: answer, startedAt: 0, updatedAt: 0, answeredInRound: 0});
  }

  function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256, uint80) {
    return (0, _rounds[latestRound].answer, 0, 0, 0);
  }
}
