//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./otokens/interfaces/IOToken.sol";
import "./PriceOracle.sol";
import "./vote-escrow/interfaces/IBoostManager.sol";

import "./interfaces/IComptroller.sol";
import "./UnitrollerAdminStorage.sol";

abstract contract ComptrollerV1Storage is IComptroller, UnitrollerAdminStorage  {
    /**
     * @notice Oracle which gives the price of any given asset
     */
    PriceOracle public override oracle;

    /**
     * @notice Multiplier used to calculate the maximum repayAmount when liquidating a borrow
     */
    uint public closeFactorMantissa;

    /**
     * @notice Multiplier representing the discount on collateral that a liquidator receives
     */
    uint public liquidationIncentiveMantissa;

    /**
     * @notice Max number of assets a single account can participate in (borrow or use as collateral)
     */
    uint public maxAssets;

    /**
     * @notice Per-account mapping of "assets you are in", capped by maxAssets
     */
    mapping(address => IOToken[]) public accountAssets;

    /// @notice Per-market mapping of "accounts in this asset"
    mapping(address => mapping(address => bool)) public accountMembership;

}

abstract contract ComptrollerV2Storage is ComptrollerV1Storage {
    struct Market {
        /// @notice Whether or not this market is listed
        bool isListed;

        bool autoCollaterize;
        /**
         * @notice Multiplier representing the most one can borrow against their collateral in this market.
         *  For instance, 0.9 to allow borrowing 90% of collateral value.
         *  Must be between 0 and 1, and stored as a mantissa.
         */
        uint collateralFactorMantissa;
    }

    /**
     * @notice Official mapping of oTokens -> Market metadata
     * @dev Used e.g. to determine if a market is supported
     */
    mapping(address => Market) public markets;


    /**
     * @notice The Pause Guardian can pause certain actions as a safety mechanism.
     *  Actions which allow users to remove their own assets cannot be paused.
     *  Liquidation / seizing / transfer can only be paused globally, not by market.
     */
    address public pauseGuardian;
    bool public _mintGuardianPaused;
    bool public _borrowGuardianPaused;
    bool public transferGuardianPaused;
    bool public seizeGuardianPaused;
    
    struct PauseData {
        bool mint;
        bool borrow;
    }

    mapping(address => PauseData) public guardianPaused;
}

abstract contract ComptrollerV3Storage is ComptrollerV2Storage {
    struct MarketState {
        /// @notice The market's last updated tokenBorrowIndex or tokenSupplyIndex
        uint224 index;

        /// @notice The timestamp the index was last updated at
        uint32 timestamp;
    }

    /// @notice A list of all markets
    IOToken[] public allMarkets;

    /// @notice The rate at which the flywheel distributes VIX, per second
    uint public compRate;

    /// @notice The portion of compRate that each market currently receives
    mapping(address => uint) public rewardSpeeds;

    /// @notice The 0VIX market supply state for each market
    mapping(address => MarketState) public supplyState;

    /// @notice The 0VIX market borrow state for each market
    mapping(address => MarketState) public borrowState;

    /// @notice The 0VIX borrow index for each market for each supplier as of the last time they accrued VIX
    mapping(address => mapping(address => uint)) public rewardSupplierIndex;

    /// @notice The 0VIX borrow index for each market for each borrower as of the last time they accrued VIX
    mapping(address => mapping(address => uint)) public rewardBorrowerIndex;

    /// @notice The VIX accrued but not yet transferred to each user
    mapping(address => uint) public rewardAccrued;
}

abstract contract ComptrollerV4Storage is ComptrollerV3Storage {
    // @notice The borrowCapGuardian can set borrowCaps to any number for any market. Lowering the borrow cap could disable borrowing on the given market.
    address public borrowCapGuardian;

    // @notice Borrow caps enforced by borrowAllowed for each oToken address. Defaults to zero which corresponds to unlimited borrowing.
    mapping(address => uint) public borrowCaps;
}

abstract contract ComptrollerV5Storage is ComptrollerV4Storage {
    /// @notice The portion of VIX that each contributor receives per second
    mapping(address => uint) public rewardContributorSpeeds;

    /// @notice Last timestamp at which a contributor's VIX rewards have been allocated
    mapping(address => uint) public lastContributorTimestamp;
}

abstract contract ComptrollerV6Storage is ComptrollerV5Storage {
    /// @notice The rate at which VIX is distributed to the corresponding borrow market (per second)
    mapping(address => uint) public rewardBorrowSpeeds;

    /// @notice The rate at which VIX is distributed to the corresponding supply market (per second)
    mapping(address => uint) public rewardSupplySpeeds;
}

abstract contract ComptrollerV7Storage is ComptrollerV6Storage {
    /// @notice Accounting storage mapping account addresses to how much VIX they owe the protocol.
    mapping(address => uint) public rewardReceivable;

    IBoostManager public boostManager;
}