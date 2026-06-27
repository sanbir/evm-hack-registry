// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../PToken/PToken.sol";
import "../PNFTToken/PNFTToken.sol";

contract UnitrollerAdminStorage {
    /// @notice Administrator for this contract
    address public admin;

    /// @notice Pending administrator for this contract
    address public pendingAdmin;

    /// @notice Active brains of Unitroller
    address public comptrollerPart1Implementation;
    address public comptrollerPart2Implementation;

    /// @notice Pending brains of Unitroller
    address public pendingComptrollerPart1Implementation;
    address public pendingComptrollerPart2Implementation;
}

contract ComptrollerNoNFTStorage is UnitrollerAdminStorage {
    /// @notice Oracle which gives the price of any given asset
    address public oracle;

    /// @notice Multiplier used to calculate the maximum repayAmount when liquidating a borrow
    uint public closeFactorMantissa;

    /// @notice Multiplier representing the discount on collateral that a liquidator receives
    uint public liquidationIncentiveMantissa;

    /// @notice Per-account mapping of "assets you are in"
    mapping(address => PToken[]) public accountAssets;

    struct Market {
        /// @notice Whether or not this market is listed
        bool isListed;

        /**
         * @notice Multiplier representing the most one can borrow against their collateral in this market.
         *  For instance, 0.9 to allow borrowing 90% of collateral value.
         *  Must be between 0 and 1, and stored as a mantissa.
         */
        uint collateralFactorMantissa;

        /// @notice Per-market mapping of "accounts in this asset"
        mapping(address => bool) accountMembership;
    }

    /**
     * @notice Official mapping of pTokens -> Market metadata
     * @dev Used e.g. to determine if a market is supported
     */
    mapping(address => Market) public markets;

    /**
     * @notice The Pause Guardian can pause certain actions as a safety mechanism.
     *  Actions which allow users to remove their own assets cannot be paused.
     *  Liquidation / seizing / transfer can only be paused globally, not by market.
     */
    address public pauseGuardian;
    bool public mintGuardianPausedGlobal;
    bool public borrowGuardianPausedGlobal;
    bool public transferGuardianPausedGlobal;
    bool public seizeGuardianPausedGlobal;
    mapping(address => bool) public mintGuardianPaused;
    mapping(address => bool) public borrowGuardianPaused;

    struct PBXMarketState {
        /// @notice The market's last updated PBXBorrowIndex or PBXSupplyIndex
        uint224 index;

        /// @notice The block number the index was last updated at
        uint32 block;
    }

    /// @notice A list of all markets
    PToken[] public allMarkets;

    /// @notice The PBX market supply state for each market
    mapping(address => PBXMarketState) public PBXSupplyState;

    /// @notice The PBX market borrow state for each market
    mapping(address => PBXMarketState) public PBXBorrowState;

    /// @notice The PBX borrow index for each market for each supplier as of the last time they accrued PBX
    mapping(address => mapping(address => uint)) public PBXSupplierIndex;

    /// @notice The PBX borrow index for each market for each borrower as of the last time they accrued PBX
    mapping(address => mapping(address => uint)) public PBXBorrowerIndex;

    /// @notice The PBX accrued but not yet transferred to each user
    mapping(address => uint) public PBXAccruedStored;

    /// @notice The borrowCapGuardian can set borrowCaps to any number for any market. Lowering the borrow cap could disable borrowing on the given market.
    address public borrowCapGuardian;

    /// @notice Borrow caps enforced by borrowAllowed for each pToken address. Defaults to zero which corresponds to unlimited borrowing.
    mapping(address => uint) public borrowCaps;

    /// @notice The portion of PBX that each contributor receives per block
    mapping(address => uint) public PBXContributorSpeeds;

    /// @notice Last block at which a contributor's PBX rewards have been allocated
    mapping(address => uint) public lastContributorBlock;

    /// @notice The PBX governance token
    address public PBXToken;

    /// @notice The rate at which PBX is distributed to the corresponding borrow market (per block)
    mapping(address => uint) public PBXBorrowSpeeds;

    /// @notice The rate at which PBX is distributed to the corresponding supply market (per block)
    mapping(address => uint) public PBXSupplySpeeds;

    /// @notice Global minimum borrow amount
    uint256 public minBorrowAmount;
}

contract ComptrollerNFTStorage is ComptrollerNoNFTStorage {
    /// @notice A list of all NFT markets
    PNFTToken[] public allNFTMarkets;

    /// @notice Per-account mapping of "assets you are in"
    mapping(address => PNFTToken[]) public accountNFTAssets;

    uint public NFTCollateralLiquidationIncentiveMantissa;

    uint public NFTCollateralLiquidationBonusPBXIncentiveMantissa;

    address public NFTXioMarketplaceZapAddress;

    /// @dev Sudoswap LSSVMRouter contract
    address public sudoswapRouterAddress;

    uint public NFTCollateralSeizeLiquidationFactorMantissa;

    /// @notice whether PToken can be used as a part of NFT liquidation process
    mapping(address => bool) public isNFTLiquidationExchangePToken;

    bool public NFTModuleClosedBeta /* = false */;

    mapping(address => bool) public NFTModuleWhitelistedUsers;

    address public uniswapV3SwapRouterAddress;
}
