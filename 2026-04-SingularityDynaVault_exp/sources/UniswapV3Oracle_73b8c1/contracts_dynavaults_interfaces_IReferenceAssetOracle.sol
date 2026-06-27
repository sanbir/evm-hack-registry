// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IReferenceAssetOracle {
	function referenceAsset() external view returns (address token);

	function tokenReferenceValue(address token, uint256 amount) external view returns (uint256 referenceValue, uint256 oldestObservation);

	function getPrice(address base, address quote) external view returns (uint256 value, uint256 oldestObservation);
}
