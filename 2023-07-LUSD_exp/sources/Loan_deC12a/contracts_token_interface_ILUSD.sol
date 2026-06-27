// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LUSD Interface
 * @author LAYER3-TEAM
 * @notice Interface of the LUSD
 */
interface ILUSD is IERC20 {
    function mint(address user, uint256 amount) external;

    function burn(address user, uint256 amount) external;
}
