// SPDX-License-Identifier: MIT

pragma solidity 0.8.22;

import {MessagingReceipt, MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {IBorrowing} from "./IBorrowing.sol";

interface ITreasury {
    error Treasury_ZeroDeposit();
    error Treasury_ZeroWithdraw();
    error Treasury_AavePoolAddressZero();
    error Treasury_AaveDepositAndMintFailed();
    error Treasury_AaveWithdrawFailed();
    error Treasury_CompoundDepositAndMintFailed();
    error Treasury_CompoundWithdrawFailed();
    error Treasury_EthTransferToCdsLiquidatorFailed();
    error Treasury_WithdrawExternalProtocolInterestFailed();
    error Treasury_WithdrawExternalProtocolDuringLiqFailed();
    error Treasury_CantBeEOAOrZeroAddress(address inputAddress);
    error Treasury_TransferFailed();
    error Treasury_ApproveFailed();
    error Treasury_ZeroAddress();
    error Treasury_InvalidAsset(IBorrowing.AssetName inputAsset);
    error Treasury_SwapFailed();

    //Depositor's Details for each depsoit.
    struct DepositDetails {
        uint64 depositedTime;
        uint128 depositedAmountInETH;
        uint128 depositedAmountUsdValue;
        uint64 downsidePercentage;
        uint128 ethPriceAtDeposit;
        uint128 borrowedAmount;
        uint128 normalizedAmount;
        bool withdrawed;
        uint128 withdrawAmount;
        bool liquidated;
        uint64 ethPriceAtWithdraw;
        uint64 withdrawTime;
        uint128 aBondTokensAmount;
        uint128 strikePrice;
        uint128 optionFees;
        uint8 APR;
        uint256 totalDebtAmountPaid;
        uint256 aBondCr;
        IBorrowing.AssetName assetName;
        uint128 exchangeRateAtDeposit;
        uint128 depositedAmount;
        uint256 optionsRenewedTimeStamp;
    }

    //Borrower Details
    struct BorrowerDetails {
        uint256 depositedAmountInETH;
        mapping(uint64 => DepositDetails) depositDetails;
        uint256 totalBorrowedAmount;
        bool hasBorrowed;
        bool hasDeposited;
        uint64 borrowerIndex;
        // uint256 depositedAmount;
    }

    //Each Deposit to Aave/Compound
    struct EachDepositToProtocol {
        uint64 depositedTime;
        uint128 depositedAmount;
        uint128 collateralPriceAtDeposit;
        uint256 depositedUsdValue;
        uint128 tokensCredited;
        bool withdrawed;
        uint128 collateralPriceAtWithdraw;
        uint64 withdrawTime;
        uint256 withdrawedUsdValue;
        uint128 interestGained;
        uint256 discountedPrice;
    }

    //Total Deposit to Aave/Compound
    struct ProtocolDeposit {
        mapping(uint64 => EachDepositToProtocol) eachDepositToProtocol;
        uint64 depositIndex;
        uint256 depositedAmount;
        uint256 totalCreditedTokens;
        uint256 exchangeRate;
        uint256 cumulativeRate;
    }

    struct DepositResult {
        bool hasDeposited;
        uint64 borrowerIndex;
    }

    struct GetBorrowingResult {
        uint64 totalIndex;
        DepositDetails depositDetails;
    }

    struct OmniChainTreasuryData {
        uint256 totalVolumeOfBorrowersAmountinWei;
        uint256 totalVolumeOfBorrowersAmountinUSD;
        uint128 noOfBorrowers;
        uint256 totalInterest;
        uint256 abondUSDaPool;
        uint256 collateralProfitsOfLiquidators;
        uint256 usdaGainedFromLiquidation;
        uint256 totalInterestFromLiquidation;
        uint256 interestFromExternalProtocolDuringLiquidation;
    }

    struct USDaOftTransferData {
        address recipient;
        uint256 tokensToSend;
    }

    struct NativeTokenTransferData {
        address recipient;
        uint256 nativeTokensToSend;
    }

    enum Protocol {
        Aave,
        Compound,
        Ionic
    }
    enum FunctionToDo {
        DUMMY,
        UPDATE,
        TOKEN_TRANSFER,
        NATIVE_TRANSFER,
        BOTH_TRANSFER
    }

    function deposit(
        address user,
        uint128 collateralPrice,
        uint64 depositTime,
        IBorrowing.AssetName assetName,
        uint256 depositingAmount
    ) external payable returns (DepositResult memory);

    function withdraw(
        address borrower,
        address toAddress,
        uint256 _amount,
        uint128 exchangeRate,
        uint64 index
    ) external payable returns (bool);

    function withdrawFromExternalProtocol(
        address user,
        uint128 aBondAmount
    ) external returns (uint256);

    function calculateYieldsForExternalProtocol(
        address user,
        uint128 aBondAmount
    ) external view returns (uint256);

    function approveTokens(
        IBorrowing.AssetName assetName,
        address spender,
        uint amount
    ) external;

    function transferEthToCdsLiquidators(
        address borrower,
        uint128 amount
    ) external;

    function noOfBorrowers() external view returns (uint128);

    function abondUSDaPool() external view returns (uint256);

    function usdaGainedFromLiquidation() external view returns (uint256);

    function totalVolumeOfBorrowersAmountinWei() external view returns (uint256);

    function totalVolumeOfBorrowersAmountLiquidatedInWei() external view returns (uint256);

    function totalVolumeOfBorrowersAmountinUSD() external view returns (uint256);

    function updateHasBorrowed(address borrower, bool _bool) external;

    function updateTotalBorrowedAmount(
        address borrower,
        uint256 amount
    ) external;

    function getTotalDeposited(
        address borrower
    ) external view returns (uint256);

    function getBorrowing(
        address depositor,
        uint64 index
    ) external view returns (GetBorrowingResult memory);

    function getCumulativeRate(
        Protocol protocol
    ) external view returns (uint128);

    function updateDepositDetails(
        address depositor,
        uint64 index,
        DepositDetails memory depositDetail
    ) external;

    function updateTotalInterest(uint256 _amount) external;

    function updateTotalInterestFromLiquidation(uint256 _amount) external;

    function updateAbondUSDaPool(uint256 amount, bool operation) external;

    function updateUSDaGainedFromLiquidation(
        uint256 amount,
        bool operation
    ) external;

    function updateInterestFromExternalProtocol(uint256 amount) external;

    function updateUsdaCollectedFromCdsWithdraw(uint256 amount) external;

    function updateLiquidatedETHCollectedFromCdsWithdraw(
        uint256 amount
    ) external;

    function updateYieldsFromLiquidatedLrts(uint256 yields) external;

    function updateTotalVolumeOfBorrowersAmountinWei(uint256 amount) external;

    function updateTotalVolumeOfBorrowersAmountinUSD(
        uint256 amountInUSD
    ) external;

    function updateDepositedCollateralAmountInWei(
        IBorrowing.AssetName asset,
        uint256 amount
    ) external;

    function updateDepositedCollateralAmountInUsd(
        IBorrowing.AssetName asset,
        uint256 amountInUSD
    ) external;

    function transferFundsToGlobal(uint256[4] memory transferAmounts) external;

    function depositedCollateralAmountInWei(
        IBorrowing.AssetName
    ) external view returns (uint256);

    function liquidatedCollateralAmountInWei(
        IBorrowing.AssetName
    ) external view returns (uint256);

    function withdrawFromExternalProtocolDuringLiq(
        address user,
        uint64 index
    ) external returns (uint256);

    function swapCollateralForUSDT(
        IBorrowing.AssetName asset,
        uint256 swapAmount,
        bytes memory odosAssembledData
    ) external returns (uint256);

    function wrapRsETH(uint256 amount) external;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event DepositToAave(uint64 count, uint256 amount);
    event WithdrawFromAave(uint64 count, uint256 amount);
    event DepositToCompound(uint64 count, uint256 amount);
    event WithdrawFromCompound(uint64 count, uint256 amount);
}
