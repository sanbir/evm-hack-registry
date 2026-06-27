// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.14;

import '@openzeppelin/contracts-upgradeable/interfaces/IERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/interfaces/IERC3156FlashLenderUpgradeable.sol';

interface IUSP is IERC20Upgradeable, IERC3156FlashLenderUpgradeable {
    function mint(address _to, uint256 _amount) external;

    function burn(uint256 amount) external;

    function burnFrom(address account, uint256 amount) external;
}
