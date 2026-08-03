// SPDX-License-Identifier: MIT

import "../interface/IOptions.sol";
import "../interface/ITreasury.sol";
import "../interface/IGlobalVariables.sol";
import "../interface/CDSInterface.sol";
import "../interface/IUSDa.sol";
import "../interface/IAbond.sol";

pragma solidity 0.8.22;

interface IBorrowing {
    error Borrow_DepositFailed();
    error Borrow_GettingETHPriceFailed();
    error Borrow_MintFailed();
    error Borrow_USDaTransferFailed();
    error Borrow_ETHTransferFailed();
    error Borrow_BurnFailed();
    error Borrow_EthTransferToCdsFailed();
    error Borrow_RenewFailed();
    error Borrow_TransferFailed();
    error Borrow_CollateralAddressesAndPriceFeedIdsMustBeSameLength();
    error Borrow_CallerIsNotAnAdmin();
    error Borrow_OnlyTreasuryCancall();
    error Borrow_Paused();
    error Borrow_OnlyCoreContractsCancall();
    error Borrow_CantBeEOAOrZeroAddress(address inputAddress);
    error Borrow_RequiredApprovalsNotMetToSet();
    error Borrow_CantBeContractOrZeroAddress(address inputAddress);
    error Borrow_MustBeNonZeroAddress(address user);
    error Borrow_CantLiquidateOwnAssets();
    error Borrow_InvalidIndex();
    error Borrow_NeedsMoreThanZero();
    error Borrow_InsufficientBalance();
    error Borrow_AlreadyWithdrewOrLiquidated();
    error Borrow_DeadlinePassed();
    error Borrow_BorrowHealthLow();
    error Borrow_LTVIsZero();
    error Borrow_NotEnoughFundInCDS();
    error Borrow_AlreadyLiquidated();
    error Borrow_AlreadyWithdrew();
    error Borrow_NotSignedByEIP712Signer();

    enum DownsideProtectionLimitValue {
        // 0: deside Downside Protection limit by percentage of eth price in past 3 months
        ETH_PRICE_VOLUME,
        // 1: deside Downside Protection limit by CDS volume divided by borrower volume.
        CDS_VOLUME_BY_BORROWER_VOLUME
    }

    enum AssetName {
        DUMMY,
        ETH,
        WeETH,
        WrsETH,
        rsETH,
        USDa,
        ABOND,
        TUSDT
    }
    enum LiquidationType {
        DUMMY,
        ONE,
        TWO,
        THREE
    }

    struct OmniChainBorrowingData {
        uint256 normalizedAmount;
        uint256 ethVaultValue;
        uint256 cdsPoolValue;
        uint256 totalCDSPool;
        uint256 ethRemainingInWithdraw;
        uint256 ethValueRemainingInWithdraw;
        uint128 noOfLiquidations;
        uint64 nonce;
    }

    struct BorrowDepositParams {
        IOptions.StrikePrice strikePercent;
        uint64 strikePrice;
        uint256 volatility;
        AssetName assetName;
        uint256 depositingAmount;
    }

    struct BorrowLibDeposit_Params {
        uint8 LTV;
        uint8 APR;
        uint256 lastCumulativeRate;
        uint256 totalNormalizedAmount;
        uint128 exchangeRate;
        uint128 ethPrice;
        uint128 lastEthprice;
    }

    struct BorrowDeposit_Result {
        uint256 totalNormalizedAmount;
        uint256 collateralRemainingInWithdraw;
        uint256 collateralValueRemainingInWithdraw;
    }

    struct BorrowWithdraw_Params {
        address toAddress;
        uint64 index;
        uint64 ethPrice;
        uint128 exchangeRate;
        uint64 withdrawTime;
        uint256 lastCumulativeRate;
        uint256 totalNormalizedAmount;
        uint64 bondRatio;
        uint256 collateralRemainingInWithdraw;
        uint256 collateralValueRemainingInWithdraw;
    }

    struct BorrowWithdraw_Result {
        uint128 downsideProtected;
        uint256 totalNormalizedAmount;
        uint256 collateralRemainingInWithdraw;
        uint256 collateralValueRemainingInWithdraw;
    }

    struct CalculateCollateralToReturn_Param {
        IOptions options;
        ITreasury.DepositDetails depositDetail;
        IGlobalVariables.OmniChainData omniChainData;
        uint128 borrowingHealth;
        uint64 ethPrice;
        uint256 collateralRemainingInWithdraw;
        uint256 collateralValueRemainingInWithdraw;
    }

    struct CalculateCollateralToReturn_Result {
        uint128 collateralToReturn;
        uint256 collateralRemainingInWithdraw;
        uint256 collateralValueRemainingInWithdraw;
        IGlobalVariables.OmniChainData omniChainData;
    }

    struct Interfaces {
        ITreasury treasury;
        IGlobalVariables globalVariables;
        IUSDa usda;
        IABONDToken abond;
        CDSInterface cds;
        IOptions options;
    }

    function getUSDValue(
        address token
    ) external view returns (uint128, uint128);

    function calculateRatio(
        uint256 _amount,
        uint128 currentEthPrice
    ) external returns (uint64);

    function assetAddress(AssetName assetName) external view returns (address);

    event Withdraw(
        address user,
        uint64 index,
        uint256 withdrawTime,
        uint128 withdrawAmount,
        uint128 noOfAbond,
        uint256 borrowDebt
    );
    event Liquidate(
        uint64 index,
        uint128 liquidationAmount,
        uint128 profits,
        uint128 ethAmount,
        uint256 availableLiquidationAmount
    );

    event Renewed(address borrower, uint64 index, uint256 timestamp);
}
