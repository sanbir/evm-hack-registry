// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IAITradeHubFundModuleContractV2 {
    function onFeeReceived(address token, uint256 amount, uint256 includedFee) external;
    function withdrawalToken( uint256 amount) external;
    function convert(uint256 paymentAmount) external;
}