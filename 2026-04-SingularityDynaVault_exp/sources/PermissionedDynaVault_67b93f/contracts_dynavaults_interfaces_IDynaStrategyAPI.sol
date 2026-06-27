// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IDynaStrategyAPI {
	function want() external view returns (address);

	function vault() external view returns (address);

	function strategist() external view returns (address);

	function isActive() external view returns (bool);

	function delegatedAssets() external view returns (uint256);

	function estimatedTotalAssets() external view returns (uint256);

	function withdraw(uint256 _amount) external returns (uint256);

	function migrate(address _newStrategy) external;

	function harvest() external;

	function tend() external;
}
