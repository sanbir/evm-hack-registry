// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IrUSDY is IERC20 {
    /**
     * @notice Function called by users to wrap their USDY tokens
     *
     * @param _USDYAmount The amount of USDY Tokens to wrap
     *
     * @dev Sanctions, Blocklist, and Allowlist checks implicit in USDY Transfer
     */
    function wrap(uint256 _USDYAmount) external;

    /**
     * @notice Function called by users to unwrap their rUSDY tokens
     *
     * @param _rUSDYAmount The amount of rUSDY to unwrap
     *
     * @dev Sanctions, Blocklist, and Allowlist checks implicit in USDY Transfer
     */
    function unwrap(uint256 _rUSDYAmount) external;
}
