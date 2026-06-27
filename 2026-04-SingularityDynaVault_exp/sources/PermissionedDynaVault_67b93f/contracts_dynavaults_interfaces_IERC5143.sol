// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "./IERC4626.sol";

// @note we had to add the postfix "CheckSlippage" to the standard IERC5143 function names,
// because type chain still has issues disambiguating overloaded functions
interface IERC5143 is IERC4626 {
	function depositCheckSlippage(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares);

	function mintCheckSlippage(uint256 shares, address receiver, uint256 maxAssets) external returns (uint256 assets);

	function withdrawCheckSlippage(uint256 assets, address receiver, address owner, uint256 maxShares) external returns (uint256 shares);

	function redeemCheckSlippage(uint256 shares, address receiver, address owner, uint256 minAssets) external returns (uint256 assets);

	// NOTE: redeemProportional is not part of the original ERC4626 standard,
	//       so it's an extension we provide on our part to ERC5143
	function redeemProportionalCheckSlippage(
		uint256 shares,
		address receiver,
		address owner,
		uint256[] memory minAssets
	) external returns (uint256[] memory assets);
}
