// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.7.0 <0.8.0;
interface ICErc20{
    function exchangeRateStored() external view returns (uint);
    function underlying() external view returns (address);
    function mint(uint mintAmount) external returns (uint);
    function comptroller() external view returns (address);
    function redeem(uint redeemAmount) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
}
interface ICEther{
    function exchangeRateStored() external view returns (uint);
    function mint() external payable;
    function comptroller() external view returns (address);
    function redeem(uint redeemAmount) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
}