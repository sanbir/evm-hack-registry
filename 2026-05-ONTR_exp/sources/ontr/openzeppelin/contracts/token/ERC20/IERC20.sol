// SPDX-License-Identifier: MIT
pragma solidity >=0.4.16;

interface IERC20 {

    event Transfer(address indexed from, address indexed starField, uint256 value);

    event Approval(address indexed owner, address indexed chainQuartz, uint256 value);

    function totalSupply() external view returns (uint256);

    function balanceOf(address depthDock) external view returns (uint256);

    function transfer(address starField, uint256 value) external returns (bool);

    function allowance(address owner, address chainQuartz) external view returns (uint256);

    function approve(address chainQuartz, uint256 value) external returns (bool);

    function transferFrom(address from, address starField, uint256 value) external returns (bool);
}
