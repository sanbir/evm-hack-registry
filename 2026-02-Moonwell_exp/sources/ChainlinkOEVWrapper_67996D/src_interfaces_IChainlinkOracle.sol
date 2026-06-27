// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.19;

import "../oracles/AggregatorV3Interface.sol";
import "../MToken.sol";

interface IChainlinkOracle {
    function getFeed(
        string memory symbol
    ) external view returns (AggregatorV3Interface);

    function getUnderlyingPrice(MToken mToken) external view returns (uint256);
}
