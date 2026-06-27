// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./ComptrollerStorage.sol";
import "../ErrorReporter.sol";

contract UnitrollerInterface is UnitrollerAdminStorage {
    /// @notice Emitted when pendingComptrollerImplementation is changed
    event NewPendingImplementations(address oldPendingPart1Implementation, address newPendingPart1Implementation, address oldPendingPart2Implementation, address newPendingPart2Implementation);

    /// @notice Emitted when pendingComptrollerImplementation is accepted, which means comptroller implementation is updated
    event NewImplementation(address oldPart1Implementation, address newPart1Implementation, address oldPart2Implementation, address newPart2Implementation);

    /// @notice Emitted when pendingAdmin is changed
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);

    /// @notice Emitted when pendingAdmin is accepted, which means admin is updated
    event NewAdmin(address oldAdmin, address newAdmin);

    /// @notice Indicator that this is a Comptroller contract (for inspection)
    function isComptroller() external pure returns (bool);

    function _setPendingImplementations(address newPendingPart1Implementation, address newPendingPart2Implementation) external;

    function _acceptImplementation() external;

    function _setPendingAdmin(address newPendingAdmin) external;

    function _acceptAdmin() external;
}

contract ComptrollerNoNFTCommonInterface is ErrorReporter, ComptrollerNoNFTStorage {
    /// @notice The initial PBX index for a market
    uint224 public constant PBXInitialIndex = 1e36;

    /// @dev closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18;

    /// @dev closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18;

    /// @dev market collateral factor must not exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18;

    /// @notice Indicator that this is a Comptroller contract (for inspection)
    function isComptroller() external pure returns (bool);

    /// @notice Emitted when an admin supports a market (marketType 0 == standard assets, 1 == nfts)
    event MarketListed(address indexed pToken, uint indexed marketType, address underlying);

    /// @notice Emitted when an account enters a market
    event MarketEntered(address indexed pToken, address indexed account);

    /// @notice Emitted when an account exits a market
    event MarketExited(address indexed pToken, address indexed account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(address indexed pToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(address oldPriceOracle, address newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused on a market or globally (pToken == 0)
    event ActionPaused(address indexed pToken, string indexed action, bool pauseState);

    /// @notice Emitted when a new borrow-side PBX speed is calculated for a market
    event PBXBorrowSpeedUpdated(PToken indexed pToken, uint newSpeed);

    /// @notice Emitted when a new supply-side PBX speed is calculated for a market
    event PBXSupplySpeedUpdated(PToken indexed pToken, uint newSpeed);

    /// @notice Emitted when a new PBX speed is set for a contributor
    event ContributorPBXSpeedUpdated(address indexed contributor, uint newSpeed);

    /// @notice Emitted when PBX is distributed to a supplier
    event DistributedSupplierPBX(PToken indexed pToken, address indexed supplier, uint compDelta, uint PBXSupplyIndex);

    /// @notice Emitted when PBX is distributed to a borrower
    event DistributedBorrowerPBX(PToken indexed pToken, address indexed borrower, uint compDelta, uint PBXBorrowIndex);

    /// @notice Emitted when borrow cap for a pToken is changed
    event NewBorrowCap(PToken indexed pToken, uint newBorrowCap);

    /// @notice Emitted when borrow cap guardian is changed
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

    /// @notice Emitted when PBX is granted by admin
    event PBXGranted(address indexed recipient, uint amount);

    event NewPBXToken(address oldPBXToken, address newPBXToken);

    function _become(address unitrollerAddress) external;
}

contract ComptrollerNFTCommonInterface is ComptrollerNoNFTCommonInterface, ComptrollerNFTStorage {
    event NFTLiquidationExchangePTokenSet(PToken indexed pToken, bool indexed enabled);

    event NewNFTCollateralLiquidationIncentive(uint oldNFTCollateralLiquidationIncentiveMantissa, uint newNFTCollateralLiquidationIncentiveMantissa);

    event NewNFTCollateralLiquidationBonusPBXIncentive(uint oldNFTCollateralLiquidationBonusPBXIncentiveMantissa, uint newNFTCollateralLiquidationBonusPBXIncentiveMantissa);

    event NewNFTCollateralSeizeLiquidationFactor(uint oldNFTCollateralSeizeLiquidationFactorMantissa, uint newNFTCollateralSeizeLiquidationFactorMantissa);
}

contract ComptrollerNoNFTPart1Interface is ComptrollerNoNFTCommonInterface {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    bool public constant isComptrollerPart1 = true;

    /*** Assets You Are In ***/

    function getAssetsIn(address account) external view returns (PToken[] memory);
    function checkMembership(address account, address pToken) external view returns (bool);
    function getDepositBorrowValues(address account) external view returns (uint, uint, uint);
    function getAllMarkets() external view returns (PToken[] memory);

    /*** Admin Functions ***/

    function _setPriceOracle(address newOracle) external;
    function _setCloseFactor(uint newCloseFactorMantissa) external;
    function _setCollateralFactor(PToken pToken, uint newCollateralFactorMantissa) external;
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external;
    function _supportMarket(PToken pToken) external;
    function _setMarketBorrowCaps(PToken[] calldata pTokens, uint[] calldata newBorrowCaps) external;
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external;
    function _setPauseGuardian(address newPauseGuardian) external;
    function _setMintPaused(address pToken, bool state) external returns (bool);
    function _setMintPausedGlobal(bool state) public returns (bool);
    function _setBorrowPaused(address pToken, bool state) external returns (bool);
    function _setBorrowPausedGlobal(bool state) public returns (bool);
    function _setTransferPaused(bool state) public returns (bool);
    function _setSeizePaused(bool state) public returns (bool);
    function _setAllPausedGlobal(bool state) external returns (bool);
    function _setPBXToken(address newPBXTokenAddress) external;
    function _setMinBorrowAmount(uint newMinBorrowAmount) external;

    /*** Policy Hooks ***/

    function mintVerify(address pToken, address minter, uint mintAmount, uint mintTokens) external;
    function redeemVerify(address pToken, address redeemer, uint redeemAmount, uint redeemTokens) external;
    function borrowVerify(address pToken, address borrower, uint borrowAmount) external;
    function repayBorrowVerify(address pToken, address payer, address borrower, uint repayAmount, uint borrowerIndex) external;
    function liquidateBorrowVerify(address pTokenBorrowed, address pTokenCollateral, address liquidator, address borrower, uint repayAmount, uint seizeTokens) external;
    function seizeVerify(address pTokenCollateral, address pTokenBorrowed, address liquidator, address borrower, uint seizeTokens) external;
    function transferVerify(address pToken, address src, address dst, uint transferTokens) external;

    /*** PBX Distribution Admin ***/

    function _setContributorPBXSpeed(address contributor, uint PBXSpeed) external;

    /*** PBX Distribution ***/

    function updateContributorRewards(address contributor) public;
}

contract ComptrollerNFTPart1Interface is ComptrollerNoNFTPart1Interface, ComptrollerNFTCommonInterface {
    /*** Assets You Are In ***/

    function getNFTAssetsIn(address account) external view returns (PNFTToken[] memory);
    function getNFTDepositValue(address account) public view returns (uint);
    function getAllNFTMarkets() external view returns (PNFTToken[] memory);

    /*** Liquidity/Liquidation Calculations ***/

    function nftLiquidateCalculateValues(address PNFTTokenAddress, uint tokenId, address NFTLiquidationExchangePToken) external view returns (uint, uint, uint, uint);
    function nftLiquidateCalculatePBXBonusIncentive(uint nftMinimumSellValueUSD) public view returns (uint);

    /*** Admin Functions ***/

    function _setNFTCollateralFactor(PNFTToken pNFTToken, uint newCollateralFactorMantissa) external;
    function _setNFTCollateralLiquidationIncentive(uint newNFTCollateralLiquidationIncentiveMantissa) external;
    function _setNFTCollateralLiquidationBonusPBX(uint newNFTCollateralLiquidationBonusPBXIncentiveMantissa) external;
    function _setNFTCollateralSeizeLiquidationFactor(uint newNFTCollateralSeizeLiquidationFactorMantissa) external;
    function _supportNFTMarket(PNFTToken pNFTToken) external;
    function _setNFTLiquidationExchangePToken(address exchangePToken, bool enabled) external;
    function _setNFTXioMarketplaceZapAddress(address newNFTXioMarketplaceZapAddress) external;
    function _setSudoswapPairRouterAddress(address newSudoswapRouterAddress) external;
    function _setUniswapV3SwapRouterAddress(address newUniswapV3SwapRouterAddress) external;
    function _setNFTModuleClosedBeta(bool newNFTModuleClosedBeta) external;
    function _NFTModuleWhitelistUser(address[] calldata whitelistedUsers) external;
    function _NFTModuleRemoveWhitelistUser(address[] calldata removedUsers) external;

    /*** Policy Hooks ***/

    function mintNFTVerify(address pNFTToken, address minter, uint tokenId) external;
    function redeemNFTVerify(address pNFTToken, address redeemer, uint tokenId) external;
    function transferNFTVerify(address pNFTToken, address src, address dst, uint tokenId) external;
    function liquidateNFTCollateralVerify(address pNFTTokenCollateral, address liquidator, address borrower, uint tokenId) external;
}

contract ComptrollerNoNFTPart2Interface is ComptrollerNoNFTCommonInterface {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    bool public constant isComptrollerPart2 = true;

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata pTokens) external;
    function exitMarket(address pToken) external returns (Error);

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(address pTokenBorrowed, address pTokenCollateral, uint repayAmount) external view returns (uint);
    function getHypotheticalAccountLiquidity(address account, address pTokenModify, uint redeemTokens, uint borrowAmount, uint redeemTokenId) public view returns (Error, uint, uint);
    function getAccountLiquidity(address account) external view returns (Error, uint, uint);
    function getCollateralBorrowValues(address account) external view returns (uint, uint, uint);

    /*** Policy Hooks ***/

    function mintAllowed(address pToken, address minter, uint mintAmount) external returns (Error);
    function redeemAllowed(address pToken, address redeemer, uint redeemTokens) external returns (Error);
    function borrowAllowed(address pToken, address borrower, uint borrowAmount) external returns (Error);
    function transferAllowed(address pToken, address src, address dst, uint transferTokens) external returns (Error);
    function repayBorrowAllowed(address pToken, address payer, address borrower, uint repayAmount) external returns (Error);
    function seizeAllowed(address pTokenCollateral, address pTokenBorrowed, address liquidator, address borrower, uint seizeTokens) external returns (Error);
    function liquidateBorrowAllowed(address pTokenBorrowed, address pTokenCollateral, address liquidator, address borrower, uint repayAmount) external returns (Error);

    /*** PBX Distribution ***/

    function claimPBXReward(address holder) external;
    function claimPBXSingle(address holder, PToken[] memory pTokens) public;
    function claimPBX(address[] memory holders, PToken[] memory pTokens, bool borrowers, bool suppliers) public;
    function PBXAccrued(address holder) public view returns (uint);

    /*** PBX Distribution Admin ***/

    function _grantPBX(address recipient, uint amount) external;
    function _setPBXSpeeds(PToken[] calldata pTokens, uint[] calldata supplySpeeds, uint[] calldata borrowSpeeds) external;
}

contract ComptrollerNFTPart2Interface is ComptrollerNoNFTPart2Interface, ComptrollerNFTCommonInterface {
    /*** Assets You Are In ***/

    function enterNFTMarkets(address[] calldata pNFTTokens) external;
    function exitNFTMarket(address pNFTToken) external returns (Error);

    /*** Liquidity/Liquidation Calculations ***/

    function nftLiquidateSendPBXBonusIncentive(uint bonusIncentive, address liquidator) external;

    /*** Policy Hooks ***/

    function mintNFTAllowed(address pNFTToken, address minter, uint tokenId) external returns (Error);
    function redeemNFTAllowed(address pToken, address redeemer, uint tokenId) external returns (Error);
    function transferNFTAllowed(address pToken, address src, address dst, uint tokenId) external returns (Error);
    function liquidateNFTCollateralAllowed(address pNFTTokenCollateral, address liquidator, address borrower, uint tokenId, address NFTLiquidationExchangePToken) external returns (Error);
}

contract ComptrollerNFTInterface is ComptrollerNFTPart1Interface, ComptrollerNFTPart2Interface { }
contract ComptrollerNoNFTInterface is ComptrollerNoNFTPart1Interface, ComptrollerNoNFTPart2Interface { }
contract ComptrollerNFTUnitrollerMergedInterface is UnitrollerInterface, ComptrollerNFTInterface { }
contract ComptrollerNoNFTUnitrollerMergedInterface is UnitrollerInterface, ComptrollerNoNFTInterface { }
