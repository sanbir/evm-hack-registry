// SPDX-License-Identifier: MIT

pragma solidity 0.8.22;

interface IonicInterface {
    
    function mint(uint256 mintAmount) external payable;
    function transfer(address dst, uint amount) external returns (bool);
    function transferFrom(address src, address dst, uint amount) external returns (bool);
    function approve(address spender, uint amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function balanceOfUnderlying(address owner) external returns (uint);
    function exchangeRateCurrent() external view returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
}