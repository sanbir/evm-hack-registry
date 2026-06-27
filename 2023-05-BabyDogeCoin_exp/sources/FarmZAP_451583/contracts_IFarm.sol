// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFarm {
    function depositOnBehalf(uint256 amount, address account) external;
    function stakeToken() external returns(address);
}
