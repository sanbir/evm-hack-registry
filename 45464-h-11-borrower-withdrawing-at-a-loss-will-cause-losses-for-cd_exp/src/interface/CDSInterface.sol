// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {MessagingReceipt, MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {IBorrowing} from "../interface/IBorrowing.sol";
import {IGlobalVariables} from "../interface/IGlobalVariables.sol";
import {ITreasury} from "../interface/ITreasury.sol";
import {IUSDa} from "../interface/IUSDa.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface CDSInterface {
    error CDS_CallerIsNotAnAdmin();
    error CDS_OnlyGlobalOrLiqCanCall();
    error CDS_OnlyBorrowCancall();
    error CDS_Paused();
    error CDS_CantBeContractOrZeroAddress(address inputAddress);
    error CDS_RequiredApprovalsNotMetToSet();
    error CDS_ShouldNotBeZero();
    error CDS_LiqAmountExceedsDepositAmount(uint128 liquidationAmount, uint256 totalDepositingAmount);
    error CDS_NeedsUSDTOnly();
    error CDS_SurplusUSDT();
    error CDS_RequiredUSDaNotMet();
    error CDS_Insufficient_USDa_Balance();
    error CDS_Insufficient_USDT_Balance();
    error CDS_USDa_TransferFailed();
    error CDS_USDT_TransferFailed();
    error CDS_ETH_PriceFeed_Failed();
    error CDS_USDa_MintFailed();
    error CDS_InvalidIndex();
    error CDS_AlreadyWithdrew();
    error CDS_WithdrawTimeNotYetReached();
    error CDS_NotEnoughFundInCDS();
    error CDS_ETH_TransferFailed();
    error CDS_NeedsMoreThanZero();
    error CDS_CantBeEOAOrZeroAddress(address inputAddress);
    error CDS_TransferFailed(IBorrowing.AssetName);
    error CDS_CantBeZeroAddress(bytes32 hashedAddress);
    error CDS_NotAnAdminTwo();

    // CDS user individual deposit details
    struct CdsAccountDetails {
        uint64 depositedTime; // deposited time
        uint256 depositedAmount; // total deposited amount
        uint64 withdrawedTime; // withdraw time
        uint256 withdrawedAmount; // total withdraw usda amount
        bool withdrawed; // whether the user has withdrew or not
        uint128 depositPrice; // deposit eth price
        uint128 depositValue; // cumulative value at deposit
        bool depositValueSign; // cumulative value sign at deposit
        bool optedLiquidation; // whether the user has opted for liq gains or not
        uint128 initialLiquidationAmount; // amount opted by user to be used for liquidation
        uint128 liquidationAmount; // updated available liquidation amount after every liquidation
        uint128 liquidationindex; // liquidation index at deposit
        uint256 normalizedAmount; // normalized amount
        uint128 lockingPeriod; // locking period chose by user
        uint128 depositedUSDa; // deposited usda
        uint128 depositedUSDT; // deposited usdt
        uint128 withdrawCollateralAmount; // withdraw liquidated collateral amount
        uint128 ethPriceAtWithdraw; // eth price during withdraw
        uint256 optionFees; // option fees gained by user
        uint256 optionFeesWithdrawn; // options fees withdrew by user
    }

    // CDS user detail
    struct CdsDetails {
        uint64 index; // total index the user has
        bool hasDeposited; // whether the user has deposited or not
        mapping(uint64 => CdsAccountDetails) cdsAccountDetails; // cds deposit details mapped to each index
    }

    // calculate value function return struct
    struct CalculateValueResult {
        uint128 currentValue;
        bool gains;
    }

    // Liquidation info to store
    struct LiquidationInfo {
        uint128 liquidationAmount; // liqudation amount needed
        uint128 profits; // profits gained in the liquidation
        uint128 collateralAmount; // collateral amount liquidated
        uint256 availableLiquidationAmount; // total available liquidation amount during the liquidation
        IBorrowing.AssetName assetName; // collateral type liquidated
        uint128 collateralAmountInETHValue; // liquidated collateral in eth value
    }

    // Liquidated collateral to give
    struct GetLiquidatedCollateralToGiveParam {
        uint256 ethAmountNeeded; // collaterla amount needed in eth
        uint256 weETHAmountNeeded; // collateral amount needed in weeth
        uint256 rsETHAmountNeeded; // collateral amount needed in rseth
        uint256 ethAvailable; // eth available
        uint256 weETHAvailable; // weeth available
        uint256 rsETHAvailable; // rseth available
        uint256 totalCollateralAvailableInETHValue; // total available in eth value
        uint128 weETHExRate; // weeth/eth exchange rate
        uint128 rsETHExRate; // rseth/eth exchange rate
    }

    struct DepositUserParams {
        uint128 usdtAmount;
        uint128 usdaAmount;
        bool liquidate;
        uint128 liquidationAmount;
        uint128 ethPrice;
        uint128 lastEthPrice;
        uint8 usdaLimit;
        uint64 usdtLimit;
        uint256 usdtAmountDepositedTillNow;
        uint256 totalCdsDepositedAmount;
        uint256 totalCdsDepositedAmountWithOptionFees;
        uint256 totalAvailableLiquidationAmount;
        uint64 cdsCount;
        uint128 lockingPeriod;
    }

    struct WithdrawUserParams {
        CdsAccountDetails cdsDepositDetails; // deposit details
        IGlobalVariables.OmniChainData omniChainData; // global data
        uint256 optionFees; // optionsfees
        uint256 optionsFeesToGetFromOtherChain; // options fees to get from otherchain
        uint256 returnAmount; // return usda amount
        uint128 ethAmount; // return eth transfer
        uint128 usdaToTransfer; // usda to transfer
        uint128 weETH_ExchangeRate; // weeth/eth exchange rate
        uint128 rsETH_ExchangeRate; // rseth/eth exchange rate
        uint256 fee; // lz fee
    }

    struct DepositResult {
        uint256 usdtAmountDepositedTillNow;
        uint256 totalCdsDepositedAmount;
        uint256 totalCdsDepositedAmountWithOptionFees;
        uint256 totalAvailableLiquidationAmount;
        uint64 cdsCount;
    }

    struct WithdrawResult {
        CdsAccountDetails cdsDepositDetails;
        IGlobalVariables.OmniChainData omniChainData;
        uint128 ethAmount;
        uint128 usdaToTransfer;
        uint256 optionFees;
        uint256 totalCdsDepositedAmount;
        uint256 totalCdsDepositedAmountWithOptionFees;
    }

    struct Interfaces {
        ITreasury treasury;
        IGlobalVariables globalVariables;
        IUSDa usda;
        IERC20 usdt;
        IBorrowing borrowing;
        CDSInterface cds;
    }

    enum FunctionName {DUMMY, BORROW_WITHDRAW, CDS_WITHDRAW }

    function totalCdsDepositedAmount() external view returns (uint256);

    function totalAvailableLiquidationAmount() external returns (uint256);

    function calculateCumulativeRate(uint128 fees) external returns (uint128);

    function calculateCumulativeValue(
        uint256 vaultBal,
        uint256 globalTotalCdsDepositedAmount,
        uint128 _price
    ) external returns (CalculateValueResult memory);

    function getCumulativeValue(
        IGlobalVariables.OmniChainData memory omniChainData,
        uint128 value,
        bool gains
    ) external returns (uint128, bool);

    function getTotalCdsDepositedAmount() external view returns (uint256);

    function getCDSDepositDetails(
        address depositor,
        uint64 index
    ) external view returns (CdsAccountDetails memory, uint64);

    function updateTotalAvailableLiquidationAmount(uint256 amount) external;

    function updateLiquidationInfo(
        uint128 index,
        LiquidationInfo memory liquidationData
    ) external;

    function updateTotalCdsDepositedAmount(uint128 _amount) external;

    function updateTotalCdsDepositedAmountWithOptionFees(
        uint128 _amount
    ) external;

    function updateDownsideProtected(uint128 downsideProtectedAmount) external;

    function verify(
        bytes memory odosExecutionData,
        bytes memory signature
    ) external view returns (bool);

    event Deposit(
        address user,
        uint64 index,
        uint128 depositedUSDa,
        uint128 depositedUSDT,
        uint256 depositedTime,
        uint128 ethPriceAtDeposit,
        uint128 lockingPeriod,
        uint128 liquidationAmount,
        bool optedForLiquidation
    );
    event Withdraw(
        address user,
        uint64 index,
        uint256 withdrawUSDa,
        uint256 withdrawTime,
        uint128 withdrawETH,
        uint128 ethPriceAtWithdraw,
        uint256 optionsFees,
        uint256 optionsFeesWithdrawn
    );
}
