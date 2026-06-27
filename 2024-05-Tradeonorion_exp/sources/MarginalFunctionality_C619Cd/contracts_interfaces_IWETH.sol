// SPDX-License-Identifier: GNU
pragma solidity ^0.8.0;

interface IWETH {
	function deposit() external payable;

    function balanceOf(address account) external view returns(uint256);

	function transfer(address to, uint value) external returns (bool);

	function withdraw(uint) external;
}
