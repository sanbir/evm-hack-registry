// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

struct PurchaseInfo {
    uint256 tier;
    uint256 amountIn;
    uint256 amountOut;
    uint256 rewards;
}

interface ILiquidityEvent {
    function mintAndStakePlp(
        uint256 _amount,
        uint256 _minUsdp,
        uint256 _minPlp
    ) external returns (uint256);

    function unstakeAndRedeemPlp(
        uint256 _plpAmount,
        uint256 _minOut,
        address _receiver
    ) external returns (uint256);

    function purchasePlp(
        uint256 _amountIn,
        uint256 _minUsdp,
        uint256 _minPlp
    ) external returns (uint256 amountOut);

    function eventEnded() external returns (bool);
}
