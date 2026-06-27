// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

interface IERC20Simple {
    function balanceOf(address account) external view returns (uint256);
	function decimals() external view returns (uint8);
}
