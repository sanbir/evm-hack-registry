// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";

interface ICorroborativeToken is IERC20 {
    function decimals() external view returns (uint8);
    function underlying() external view returns (address);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}
