// SPDX-License-Identifier: MIT

pragma solidity 0.8.22;

import "./CDSInterface.sol";
import "./IBorrowing.sol";

interface IBorrowLiquidation {
    error BorrowLiquidation_LiquidateBurnFailed();
    error BorrowLiq_ApproveFailed();

    function liquidateBorrowPosition(
        address user,
        uint64 index,
        uint64 currentEthPrice,
        IBorrowing.LiquidationType liquidationType,
        uint256 lastCumulativeRate
    ) external payable returns (CDSInterface.LiquidationInfo memory);

    function closeThePositionInSynthetix() external;

    function executeOrdersInSynthetix(
        bytes[] calldata priceUpdateData
    ) external;

    event Liquidate(
        uint64 index,
        uint128 liquidationAmount,
        uint128 profits,
        uint128 ethAmount,
        uint256 availableLiquidationAmount
    );
}
