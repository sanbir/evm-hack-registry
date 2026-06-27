// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

library Constants {

    uint64 public constant PERCENT_RATE = 317097920;

    // Interest  
    uint16 public constant BASIS_POINTS_DENOM = 1e4; 

    // Core
    uint256 public constant COLLATERIZATION_RATE_PRECISION = 1e5;  

    // Rates 
    uint256 public constant EXCHANGE_RATE_PRECISION = 1e18;
    uint256 public constant LIQUIDATION_MULTIPLIER_PRECISION = 1e5;

    // Fees
    uint256 public constant BORROW_OPENING_FEE_PRECISION = 1e5;   

    // Distribution
    uint256 public constant DISTRIBUTION_PART = 10; 
    uint256 public constant DISTRIBUTION_PRECISION = 100;

    uint8 public constant OPERATION_REPAY = 2;
    uint8 public constant OPERATION_REMOVE_COLLATERAL = 4;
    uint8 public constant OPERATION_BORROW = 5;
    uint8 public constant OPERATION_GET_REPAY_SHARE = 6;
    uint8 public constant OPERATION_GET_REPAY_PART = 7;
    uint8 public constant OPERATION_ACCRUE = 8;
    uint8 public constant OPERATION_ADD_COLLATERAL = 10;
    uint8 public constant OPERATION_UPDATE_PRICE = 11;
    uint8 public constant OPERATION_BENTO_DEPOSIT = 20;
    uint8 public constant OPERATION_BENTO_WITHDRAW = 21;
    uint8 public constant OPERATION_BENTO_TRANSFER = 22;
    uint8 public constant OPERATION_BENTO_TRANSFER_MULTIPLE = 23;
    uint8 public constant OPERATION_BENTO_SETAPPROVAL = 24;
    uint8 public constant OPERATION_CALL = 30;
    uint8 public constant OPERATION_LIQUIDATE = 31;
    uint8 public constant OPERATION_CUSTOM_START_INDEX = 100;

    int256 public constant USE_PARAM1 = -1;
    int256 public constant USE_PARAM2 = -2;
}