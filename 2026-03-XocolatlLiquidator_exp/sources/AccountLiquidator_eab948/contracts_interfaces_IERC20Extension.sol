// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IAccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/IAccessControlUpgradeable.sol";

interface IERC20Extension is IERC20Upgradeable, IAccessControlUpgradeable {
    function decimals() external view returns (uint256);

    function mint(address to, uint256 amount) external;

    function burn(address to, uint256 amount) external;
}
