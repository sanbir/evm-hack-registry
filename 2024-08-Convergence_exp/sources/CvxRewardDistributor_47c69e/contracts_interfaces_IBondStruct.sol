// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IBondStruct {
    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        STORED STRUCTS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    struct BondParams {
        /**
         * @dev Type of function used to compute the actual ROI of a bond.
         *      - 0 is SquareRoot
         *      - 1 is Ln
         *      - 2 is Square
         *      - 3 is Linear
         */
        BondFunction composedFunction;
        /// @dev Address of the underlaying token of the bond.
        address token;
        /**
         * @dev Gamma is used in the BondCalculator.It's the value dividing the ratio between the amount already sold and the theorical amount sold.
         *      250_000 correspond to 0.25 (25%).
         */
        uint40 gamma;
        /// @dev Total duration of the bond, uint40 is enough for a timestamp.
        uint40 bondDuration;
        /// @dev Determine if a Bond is paused. Can't deposit on a bond paused.
        bool isPaused;
        /**
         * @dev Scale is used in the BondCalculator. When a scale is A, the ROI vary by incremental of A.
         *      If scale is 5_000 correspond to 0.5%, the ROI will vary from the maxROI to minROI by increment of 0.5%.
         */
        uint32 scale;
        /**
         * @dev Minimum ROI of the bond. Discount cannot be less than the minROI.
         *      If minRoi is 100_000, it represents 10%.
         */

        uint24 minRoi;
        /**
         * @dev Maximum ROI of the bond. Discount cannot be more than the maxROI.
         *      If maxRoi is 150_000, it represents 15%.
         */
        uint24 maxRoi;
        /**
         * @dev Percentage maximum of the cvgToSell that an user can buy in one deposit
         *      If percentageOneTx is 200, it represents 20% of cvgToSell.
         */
        uint24 percentageOneTx;
        /// @dev Duration of the vesting in second.
        uint32 vestingTerm;
        /**
         * @dev Maximum amount that can be bought through this bond.
         *      uint80 represents 1.2M tokens in ethers. It means that we are never going to open a bond with more than 1.2M tokens.
         */
        uint80 cvgToSell; // Limit of Max CVG to sell => 1.2M CVG max approx
        /// @dev Timestamp in second of the beginning of the bond. Has to be in the future.
        uint40 startBondTimestamp;
    }
    struct BondPending {
        /// @dev Timestamp in second of the last interaction with this position.
        uint64 lastTimestamp;
        /// @dev Time in seconds lefting before the position is fully unvested
        uint64 vestingTimeLeft;
        /**
         * @dev Total amount of CVG still vested in the position.
         *      uint128 is way enough because it's an amount in CVG that have a max supply of 150M tokens.
         */
        uint128 leftClaimable;
    }

    struct BondCreateStruct {
        /// @dev Timestamp in second of the last interaction with this position.
        BondParams bondParams;
        /// @dev Time in seconds lefting before the position is fully unvested
        bool isLockMandatory;
    }

    enum BondFunction {
        SQRT,
        LN,
        POWER_2,
        LINEAR
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        VIEW STRUCTS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    struct BondTokenView {
        uint128 lastTimestamp;
        uint128 vestingEnd;
        uint256 claimableCvg;
        uint256 leftClaimable;
    }

    struct BondView {
        uint256 actualRoi;
        uint256 cvgAlreadySold;
        uint256 usdExecutionPrice;
        uint256 usdLimitPrice;
        uint256 assetBondPrice;
        uint256 usdBondPrice;
        bool isOracleValid;
        BondParams bondParameters;
        ERC20View token;
    }

    struct BondViewV2 {
        uint256 actualRoi;
        uint256 cvgAlreadySold;
        uint256 usdExecutionPrice;
        uint256 usdLimitPrice;
        uint256 assetBondPrice;
        uint256 usdBondPrice;
        bool isOracleValid;
        BondParams bondParameters;
        ERC20View token;
        bool isLockingMandatory;
    }

    struct ERC20View {
        string token;
        address tokenAddress;
        uint256 decimals;
    }
    struct TokenVestingInfo {
        uint256 term;
        uint256 claimable;
        uint256 pending;
    }
}
