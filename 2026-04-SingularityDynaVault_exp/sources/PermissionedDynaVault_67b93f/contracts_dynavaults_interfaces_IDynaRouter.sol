// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./IDynaRouterAPI.sol";

interface IDynaRouter is IDynaRouterAPI {
	function getRegistry() external view returns (address);
}
