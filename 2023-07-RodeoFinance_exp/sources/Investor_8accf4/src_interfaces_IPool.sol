// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IPool {
    function paused() external view returns (bool);
    function asset() external view returns (address);
    function oracle() external view returns (address);
    function rateModel() external view returns (address);
    function borrowMin() external view returns (uint256);
    function borrowFactor() external view returns (uint256);
    function liquidationFactor() external view returns (uint256);
    function amountCap() external view returns (uint256);
    function index() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalBorrow() external view returns (uint256);
    function getUpdatedIndex() external view returns (uint256);
    function mint(uint256, address) external;
    function borrow(uint256) external returns (uint256);
    function repay(uint256) external returns (uint256);
}
