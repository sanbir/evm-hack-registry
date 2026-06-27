// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../libraries/LibFeeManager.sol";
import "./IPairsManager.sol";
import {CommissionInfo} from "./IBrokerManager.sol";

interface IFeeManager {

    event AddFeeConfig(
        uint16 indexed index, uint16 openFeeP, uint16 closeFeeP, uint24 shareP, uint24 minCloseFeeP, string name
    );
    event RemoveFeeConfig(uint16 indexed index);
    event UpdateFeeConfig(uint16 indexed index,
        uint16 openFeeP, uint16 closeFeeP,
        uint24 shareP, uint24 minCloseFeeP
    );
    event SetDaoRepurchase(address indexed oldDaoRepurchase, address daoRepurchase);
    event SetRevenueAddress(address indexed oldRevenueAddress, address revenueAddress);
    event OpenFee(
        address indexed token, uint256 totalFee, uint256 daoAmount,
        uint24 brokerId, uint256 brokerAmount, uint256 alpPoolAmount
    );
    event CloseFee(
        address indexed token, uint256 totalFee, uint256 daoAmount,
        uint24 brokerId, uint256 brokerAmount, uint256 alpPoolAmount
    );
    event PredictionOpenFee(
        address indexed token, uint256 totalFee, uint256 daoAmount,
        uint24 brokerId, uint256 brokerAmount, uint256 alpPoolAmount
    );
    event PredictionCloseFee(
        address indexed token, uint256 totalFee, uint256 daoAmount,
        uint24 brokerId, uint256 brokerAmount, uint256 alpPoolAmount
    );
    event WithdrawRevenue(address indexed token, address indexed operator, uint256 amount);

    struct FeeDetail {
        // total accumulated fees, include DAO/referral fee
        uint256 total;
        // accumulated DAO repurchase funds
        uint256 daoAmount;
        uint256 brokerAmount;
        uint256 alpPoolAmount;
    }

    function addFeeConfig(
        uint16 index, string calldata name, uint16 openFeeP, uint16 closeFeeP, uint24 shareP, uint24 minCloseFeeP
    ) external;

    function removeFeeConfig(uint16 index) external;

    function updateFeeConfig(uint16 index, uint16 openFeeP, uint16 closeFeeP, uint24 shareP, uint24 minCloseFeeP) external;

    function setDaoRepurchase(address daoRepurchase) external;

    function setRevenueAddress(address revenueAddress) external;

    function getFeeConfigByIndex(uint16 index) external view returns (LibFeeManager.FeeConfig memory, IPairsManager.PairSimple[] memory);

    function getFeeDetails(address[] calldata tokens) external view returns (FeeDetail[] memory);

    function feeAddress() external view returns (address daoRepurchase, address revenueAddress);

    function revenues(address[] calldata tokens) external view returns (CommissionInfo[] memory);

    function chargeOpenFee(address token, uint256 openFee, uint24 broker) external returns (uint24);

    function chargePredictionOpenFee(address token, uint256 openFee, uint24 broker) external returns (uint24);

    function chargeCloseFee(address token, uint256 closeFee, uint24 broker) external;

    function chargePredictionCloseFee(address token, uint256 closeFee, uint24 broker) external;

    function withdrawRevenue(address[] calldata tokens) external;
}
