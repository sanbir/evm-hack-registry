// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IPerpPair {

    struct ClampParameters{
        uint256 minFR;
        uint256 maxFR;
        uint256 offset;
    }

    error AccessControlBadConfirmation();
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);
    error ReentrancyGuardReentrantCall();
    error SafeCastOverflowedIntToUint(int256 value);
    error SafeCastOverflowedUintToInt(uint256 value);

    event ClosedPosition(address indexed user, uint256 pnl, bool pnlSign);
    event ClosedTrade(
        address indexed user,
        bytes32 indexed id,
        bool direction,
        uint256 tradeSize,
        uint256 tradeReturn,
        uint256 currentPrice,
        int256 deltaPnl
    );
    event EnabledAutoClose(address indexed user, uint256 profitTh, uint256 lossTh);
    event ExecutedTrade(
        address indexed user,
        bytes32 indexed id,
        bool direction,
        uint256 tradeSize,
        uint256 tradeReturn,
        uint256 currentPrice,
        uint256 leverage
    );
    event LiquidatedUser(
        address indexed user,
        address liquidator,
        uint256 fraction,
        uint256 liquidationFee,
        uint256 positionSize,
        uint256 currentPrice,
        int256 deltaPnl,
        bool liquidationDirection
    );
    event LiquidityAdded(
        address indexed user,
        uint256 liquidityStable,
        uint256 liquidityAsset,
        uint256 InitialSharesStable,
        uint256 InitialSharesAsset,
        int256[2][2] invSnap,
        uint256 globalSharesStable,
        uint256 globalSharesAsset,
        uint256 fee
    );
    event LiquidityRemoved(
        address indexed user,
        uint256 liquidityStableRemoved,
        uint256 liquidityAssetRemoved,
        uint256 burntSharesStable,
        uint256 burntSharesAsset,
        uint256 feeValue
    );
    event LockedParameterUpdate(
        uint256 paramLockedUntil,
        uint256 _MMR,
        uint256 _fullLiquidationStep,
        uint256 _partialLiquidationFraction,
        uint256 _tradingFee,
        uint256 _flatTradingFee,
        uint256 _feeLP,
        uint256 _liquidityMinFee,
        uint256 _liquidityMaxFee,
        uint256 _liquidityFeeK,
        uint256 _fundingC,
        ClampParameters _clampParams,
        uint256 _paramTimeLock,
        uint256 _minimumTradeSize
    );
    event ParametersUpdated(
        address _oracle,
        uint256 _feeFrontend,
        address _feeProtocolAddr,
        uint256 _insuranceFundCap,
        uint256 _maxLeverage,
        uint256 _liquidationDiscount
    );
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function MMR() external view returns (uint256);
    function MOD_ROLE() external view returns (bytes32);
    function _computeFundingFee(address user, uint256 _fundingRate, bool _fundingRateSign)
        external
        view
        returns (uint256 localFundingFee, bool localFundingFeeSign);
    function addLiquidity(
        uint256 liquidityStable,
        uint256 liquidityAsset,
        uint256 maxFeeValue,
        bytes memory unverifiedReport
    ) external;
    function autoCloseFee() external view returns (uint256);
    function autoCloseUserPosition(address user, address frontendAddress, bytes memory unverifiedReport) external;
    function autoCloseUsersData(address)
        external
        view
        returns (bool authorized, uint256 profitTh, uint256 lossTh, uint256 maxSlippage, uint256 maxLiqFee);
    function calcPnL(address user, uint256 price) external view returns (uint256, bool);
    function clampParameters() external view returns (uint256 minFR, uint256 maxFR, uint256 offset);
    function closeAndWithdraw(
        uint256 maxSlippage,
        uint256 maxLiqFee,
        address frontendAddress,
        bytes memory unverifiedReport
    ) external;
    function closeTrade(
        bool direction,
        uint256 size,
        uint256 minTradeReturn,
        uint256 initialGuess,
        bytes32 tradeID,
        uint256 openSize,
        address frontendAddress,
        bytes memory unverifiedReport
    ) external;
    function computeFundingFee(address user)
        external
        view
        returns (uint256 localFundingFee, bool localFundingFeeSign);
    function computeFundingRate(uint256 price, uint256 timestamp) external view returns (uint256, bool);
    function curveParameters()
        external
        view
        returns (
            uint256 shortCurveParameterA,
            uint256 shortCurveParameterB,
            uint256 longCurveParameterA,
            uint256 longCurveParameterB,
            uint256 lastCurveUpdate,
            uint256 curveUpdateInterval,
            bool lastTradeDirection,
            uint256 lastValidatedPrice
        );
    function disableAutoClose() external;
    function dx0() external view returns (uint256);
    function dy0() external view returns (uint256);
    function enableAutoClose(uint256 profitTh, uint256 lossTh, uint256 maxSlippage, uint256 maxLiqFee) external;
    function feeFrontend() external view returns (uint256);
    function feeLP() external view returns (uint256);
    function feeProtocolAddr() external view returns (address);
    function flatTradingFee() external view returns (uint256);
    function fullLiquidationStep() external view returns (uint256);
    function fundingC() external view returns (uint256);
    function fundingInterval() external view returns (uint256);
    function fundingRate() external view returns (uint256);
    function fundingRateSign() external view returns (bool);
    function getCollateral(address user) external view returns (uint256);
    function getLpLiquidityBalance(address user) external view returns (uint256, uint256);
    function getLpLiquidityShares(address user) external view returns (uint256, uint256);
    function getPrice() external view returns (uint256);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function globalLiquidityAsset() external view returns (uint256);
    function globalLiquidityStable() external view returns (uint256);
    function globalSharesAsset() external view returns (uint256);
    function globalSharesStable() external view returns (uint256);
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function insuranceFund() external view returns (uint256);
    function insuranceFundCap() external view returns (uint256);
    function insuranceFundSign() external view returns (bool);
    function isTrustedForwarder(address forwarder) external view returns (bool);
    function lastOperationTimestamp() external view returns (uint256);
    function liquidate(address user, uint256 liquidatedPositionSize, bytes memory unverifiedReport) external;
    function liquidationDiscount() external view returns (uint256);
    function liquidityFeeK() external view returns (uint256);
    function liquidityM(uint256, uint256) external view returns (int256);
    function liquidityMaxFee() external view returns (uint256);
    function liquidityMinFee() external view returns (uint256);
    function liquidityPosition(address)
        external
        view
        returns (uint256 initialStableShares, uint256 initialAssetShares, uint256 debtStable, uint256 debtAsset);
    function maxLpLeverage() external view returns (uint256);
    function minimumLiquidityMovement() external view returns (uint256);
    function minimumTradeSize() external view returns (uint256);
    function trade(
        bool direction,
        uint256 size,
        uint256 minTradeReturn,
        uint256 initialGuess,
        address frontendAddress,
        uint8 leverage,
        bytes memory unverifiedReport
    ) external returns (uint256);
    function oracle() external view returns (address);
    function oracleDecimals() external view returns (uint256);
    function partialLiquidationFraction() external view returns (uint256);
    function prepareTimeLockedParameters(
        uint256 _MMR,
        uint256 _fullLiquidationStep,
        uint256 _tradingFee,
        uint256 _flatTradingFee,
        uint256 _feeLP,
        uint256 _liquidityMinFee,
        uint256 _liquidityMaxFee,
        uint256 _liquidityFeeK,
        uint256 _fundingC,
        ClampParameters memory _clampParams,
        uint256 _paramTimeLock,
        uint256 _partialLiquidationFraction,
        uint256 _minimumTradeSize
    ) external;
    function ReadParameters()
    external
    view
    returns (
        address vault_,
        uint256 minimumTradeSize_,
        uint256 minimumLiquidityMovement_,
        uint256 feeFrontend_,
        uint256 feeLP_,
        uint256 insuranceFundCap_
    );
    function realizePnL(bytes calldata unverifiedReport) external;
    function removeLiquidity(
        uint256 liquidityStableToRemove,
        uint256 liquidityAssetToRemove,
        uint256 maxFeeValue,
        bytes memory unverifiedReport
    ) external;
    function renounceRole(bytes32 role, address callerConfirmation) external;
    function revokeRole(bytes32 role, address account) external;
    function setTimeLockedParameters(
        uint256 _MMR,
        uint256 _fullLiquidationStep,
        uint256 _tradingFee,
        uint256 _flatTradingFee,
        uint256 _feeLP,
        uint256 _liquidityMinFee,
        uint256 _liquidityMaxFee,
        uint256 _liquidityFeeK,
        uint256 _fundingC,
        ClampParameters memory _clampParams,
        uint256 _paramTimeLock,
        uint256 _partialLiquidationFraction,
        uint256 _minimumTradeSize
    ) external;
    function setUnguardedParameters(
        address _oracle,
        uint256 _feeFrontend,
        address _feeProtocolAddr,
        uint256 _insuranceFundCap,
        uint256 _maxLeverage,
        uint256 _liquidationDiscount,
        uint256 _maxLpLeverage
    ) external;
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    function tickerAssetCurrency() external view returns (string memory);
    function totalTraderExposure() external view returns (uint256);
    function totalTraderExposureSign() external view returns (bool);
    function tradingFee() external view returns (uint256);
    function trustedForwarder() external view returns (address);
    function updateFG(bytes memory unverifiedReport) external;
    function userVirtualTraderPosition(address)
        external
        view
        returns (
            uint256 balanceStable,
            uint256 balanceAsset,
            uint256 debtStable,
            uint256 debtAsset,
            uint256 fundingFee,
            bool fundingFeeSign,
            uint256 initialFundingRate,
            bool initialFundingRateSign
        );
    function vault() external view returns (address);
}
