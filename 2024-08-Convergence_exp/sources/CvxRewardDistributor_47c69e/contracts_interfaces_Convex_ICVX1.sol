// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface ICVX1 is IERC20Metadata {
    function mint(address to, uint256 amount) external;
    function mintFrom(address from, address to, uint256 amount) external;
    function stake() external;

    function withdraw(uint256 _amount, address receiver) external;

    function withdrawFrom(uint256 amount, address from, address to) external;
}
