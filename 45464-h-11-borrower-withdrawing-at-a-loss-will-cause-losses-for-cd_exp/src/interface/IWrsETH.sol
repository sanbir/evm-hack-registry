// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IWrsETH {

    function approve(address spender, uint _amount) external returns (bool);

    function deposit(address asset, uint256 _amount) external;

    function depositTo(address asset, address _to, uint256 _amount) external;

    function withdraw(address asset, uint256 _amount) external;

    function withdrawTo(address asset, address _to, uint256 _amount) external;
    
}