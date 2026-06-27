// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

// Libraries
import {UniswapPoolAddress} from "./libraries/UniswapPoolAddress.sol";
import {SirStructs} from "./libraries/SirStructs.sol";

/**
 * @notice The Oracle contract is our interface to Uniswap v3 pools and their oracle data.
 * It allows the SIR protocol to retrieve the TWAP of any pair of tokens,
 * without worrying about which fee tier to use, nor whether the pool exists,
 * nor if the TWAP is initialized to the proper length.
 * This oracle is permissionless and requires no administrative access.
 */
contract Oracle {
    error NoUniswapPool();
    error UniswapFeeTierIndexOutOfBounds();
    error OracleAlreadyInitialized();
    error OracleNotInitialized();

    event UniswapFeeTierAdded(uint24 fee);
    event OracleInitialized(
        address indexed token0,
        address indexed token1,
        uint24 feeTierSelected,
        uint136 avLiquidity,
        uint40 period
    );
    event PriceUpdated(address indexed token0, address indexed token1, bool priceTruncated, int64 priceTickX42);

    event UniswapOracleProbed(
        uint24 fee,
        int56 aggPriceTick,
        uint136 avLiquidity,
        uint40 period,
        uint16 cardinalityToIncrease
    );
    event OracleFeeTierChanged(uint24 feeTierPrevious, uint24 feeTierSelected);

    // This struct is used to pass data between functions.
    struct UniswapOracleData {
        IUniswapV3Pool uniswapPool; // Uniswap v3 pool
        int56 aggPriceTick; // Aggregated log price over the period
        uint136 avLiquidity; // Aggregated in-range liquidity over period
        uint40 period; // Duration of the current TWAP
        uint16 cardinalityToIncrease; // Cardinality suggested for increase
    }

    // Constants
    address private immutable UNISWAPV3_FACTORY;
    uint256 internal constant DURATION_UPDATE_FEE_TIER = 25 hours; // No need to test if there is a better fee tier more often than this
    int64 internal constant MAX_TICK_INC_PER_SEC = 1 << 42;
    uint40 internal constant TWAP_DELTA = 1 minutes; // When a new fee tier has larger liquidity, the TWAP array is increased in intervals of TWAP_DELTA.
    uint16 internal constant CARDINALITY_DELTA = uint16((TWAP_DELTA - 1) / (12 seconds)) + 1;
    uint40 public constant TWAP_DURATION = 30 minutes;

    // State variables
    mapping(address token0 => mapping(address token1 => SirStructs.OracleState)) internal _state;

    // Least significant 8 bits represent the length of this tightly packed array, 48 bits for each extra fee tier, which implies a maximum of 5 extra fee tiers.
    uint private _uniswapExtraFeeTiers;

    constructor(address uniswapV3Factory) {
        UNISWAPV3_FACTORY = uniswapV3Factory;
    }

    /*////////////////////////////////////////////////////////////////
                            READ-ONLY FUNCTIONS
    /////////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the state of the oracle for the pair of tokens.
     * @dev The tokens must be sorted lexicographically.
     */
    function state(address token0, address token1) external view returns (SirStructs.OracleState memory) {
        require(token0 < token1);
        return _state[token0][token1];
    }

    /**
     * @notice Returns the uniswap fee tier of the pair of tokens.
     * @dev The order of the tokens does not matter.
     */
    function uniswapFeeTierOf(address tokenA, address tokenB) external view returns (uint24) {
        (tokenA, tokenB) = _orderTokens(tokenA, tokenB);
        return _state[tokenA][tokenB].uniswapFeeTier.fee;
    }

    /**
     * @notice Returns the address of the uniswap pool for the pair of tokens.
     * @dev The order of the tokens does not matter.
     */
    function uniswapFeeTierAddressOf(address tokenA, address tokenB) external view returns (address) {
        (tokenA, tokenB) = _orderTokens(tokenA, tokenB);
        return
            UniswapPoolAddress.computeAddress(
                UNISWAPV3_FACTORY,
                UniswapPoolAddress.getPoolKey(tokenA, tokenB, _state[tokenA][tokenB].uniswapFeeTier.fee)
            );
    }

    /**
     * @notice Function for getting all the uniswap fee tiers.
     * @dev If a new fee tier is added, anyone can add it using the 'newUniswapFeeTier' function.
     */
    function getUniswapFeeTiers() public view returns (SirStructs.UniswapFeeTier[] memory uniswapFeeTiers) {
        unchecked {
            // Find out # of all possible fee tiers
            uint uniswapExtraFeeTiers_ = _uniswapExtraFeeTiers;
            uint numUniswapExtraFeeTiers = uint(uint8(uniswapExtraFeeTiers_));

            uniswapFeeTiers = new SirStructs.UniswapFeeTier[](4 + numUniswapExtraFeeTiers); // Unchecked is safe because 4+numUniswapExtraFeeTiers ≤ 4+5 ≤ 2^256-1
            uniswapFeeTiers[0] = SirStructs.UniswapFeeTier(100, 1);
            uniswapFeeTiers[1] = SirStructs.UniswapFeeTier(500, 10);
            uniswapFeeTiers[2] = SirStructs.UniswapFeeTier(3000, 60);
            uniswapFeeTiers[3] = SirStructs.UniswapFeeTier(10000, 200);

            // Extra fee tiers
            if (numUniswapExtraFeeTiers > 0) {
                uniswapExtraFeeTiers_ >>= 8;
                for (uint i = 0; i < numUniswapExtraFeeTiers; ++i) {
                    uniswapFeeTiers[4 + i] = SirStructs.UniswapFeeTier(
                        uint24(uniswapExtraFeeTiers_),
                        int24(uint24(uniswapExtraFeeTiers_ >> 24))
                    );
                    uniswapExtraFeeTiers_ >>= 48;
                }
            }
        }
    }

    /// @notice Returns the TWAP price for the collateralToken-debtToken pair.
    function getPrice(address collateralToken, address debtToken) external view returns (int64) {
        unchecked {
            (address token0, address token1) = _orderTokens(collateralToken, debtToken);

            // Get oracle _state
            SirStructs.OracleState memory oracleState = _state[token0][token1];
            if (!oracleState.initialized) revert OracleNotInitialized();

            // Get latest price if not stored
            if (oracleState.timeStampPrice != block.timestamp) {
                // Update price
                UniswapOracleData memory oracleData = _uniswapOracleData(
                    token0,
                    token1,
                    oracleState.uniswapFeeTier.fee
                );

                // oracleData.period == 0 is not possible because it would mean the pool is not initialized
                if (oracleData.period == 1) {
                    /** If the fee tier has been updated this block
                    AND the cardinality of the selected fee tier is 1,
                    THEN the price is unavailable as TWAP.
                */
                    (, int24 tick, , , , , ) = oracleData.uniswapPool.slot0();
                    oracleData.aggPriceTick = tick;
                }

                _updatePrice(oracleState, oracleData);
            }

            // Invert price if necessary
            return collateralToken == token1 ? -oracleState.tickPriceX42 : oracleState.tickPriceX42; // Unchecked is safe because |tickPriceX42| ≤ MAX_TICK_X42
        }
    }

    /*////////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    /////////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the oracleState for a pair of tokens.
     * @dev Anyone can call it, but it's a no-op if already initialized.
     */
    function initialize(address tokenA, address tokenB) external {
        unchecked {
            (tokenA, tokenB) = _orderTokens(tokenA, tokenB);

            // Get oracle _state
            SirStructs.OracleState memory oracleState = _state[tokenA][tokenB];
            if (oracleState.initialized) return; // No-op return because reverting would cause SIR to fail creating new vaults

            // Get all fee tiers
            SirStructs.UniswapFeeTier[] memory uniswapFeeTiers = getUniswapFeeTiers();
            uint256 numUniswapFeeTiers = uniswapFeeTiers.length;

            // Find the best fee tier by weighted liquidity
            uint256 score;
            UniswapOracleData memory oracleData;
            UniswapOracleData memory bestOracleData;
            for (uint i = 0; i < numUniswapFeeTiers; ++i) {
                // Retrieve average liquidity
                oracleData = _uniswapOracleData(tokenA, tokenB, uniswapFeeTiers[i].fee);
                emit UniswapOracleProbed(
                    uniswapFeeTiers[i].fee,
                    oracleData.aggPriceTick,
                    oracleData.avLiquidity,
                    oracleData.period,
                    oracleData.cardinalityToIncrease
                );

                if (oracleData.avLiquidity > 0) {
                    /** Compute scores.
                        We weight the average liquidity by the duration of the TWAP because
                        we do not want to select a fee tier whose liquidity is easy manipulated.
                            avLiquidity * period = aggregate Liquidity
                    */
                    uint256 scoreTemp = _feeTierScore(
                        uint256(oracleData.avLiquidity) * oracleData.period, // Safe because avLiquidity * period < 2^136 * 2^40 = 2^170
                        uniswapFeeTiers[i]
                    );

                    // Update best score
                    if (scoreTemp > score) {
                        oracleState.indexFeeTier = uint8(i);
                        bestOracleData = oracleData;
                        score = scoreTemp;
                    }
                }
            }

            if (score == 0) revert NoUniswapPool();
            oracleState.indexFeeTierProbeNext = (oracleState.indexFeeTier + 1) % uint8(numUniswapFeeTiers); // Safe because indexFeeTier+1 < 9+1 < 2^8-1
            oracleState.initialized = true;
            oracleState.uniswapFeeTier = uniswapFeeTiers[oracleState.indexFeeTier];
            oracleState.timeStampFeeTier = uint40(block.timestamp);

            // We increase the cardinality of the selected tier if necessary
            if (bestOracleData.cardinalityToIncrease > 0) {
                bestOracleData.uniswapPool.increaseObservationCardinalityNext(bestOracleData.cardinalityToIncrease);
            }

            // Update oracle _state
            _state[tokenA][tokenB] = oracleState;

            emit OracleInitialized(
                tokenA,
                tokenB,
                oracleState.uniswapFeeTier.fee,
                bestOracleData.avLiquidity,
                bestOracleData.period
            );
        }
    }

    /// @notice Anyone can let SIR know that a new fee tier exists in Uniswap V3
    function newUniswapFeeTier(uint24 fee) external {
        require(fee > 0);

        // Get all fee tiers
        SirStructs.UniswapFeeTier[] memory uniswapFeeTiers = getUniswapFeeTiers();
        uint256 numUniswapFeeTiers = uniswapFeeTiers.length;

        // Check there is space to add a new fee tier
        require(numUniswapFeeTiers < 9); // 4 basic fee tiers + 5 extra fee tiers max

        // Check fee tier actually exists in Uniswap v3
        int24 tickSpacing = IUniswapV3Factory(UNISWAPV3_FACTORY).feeAmountTickSpacing(fee);
        require(tickSpacing > 0);

        // Check fee tier has not been added yet
        for (uint256 i = 0; i < numUniswapFeeTiers; ++i) {
            require(fee != uniswapFeeTiers[i].fee);
        }

        // Add new fee tier
        _uniswapExtraFeeTiers |= (uint(fee) | (uint(uint24(tickSpacing)) << 24)) << (8 + 48 * (numUniswapFeeTiers - 4)); // Safe because uniswapFeeTiers's min length is 4 and it is a uint256

        // Increase count
        uint numUniswapExtraFeeTiers = uint(uint8(_uniswapExtraFeeTiers));
        _uniswapExtraFeeTiers &= (2 ** 240 - 1) << 8;
        _uniswapExtraFeeTiers |= numUniswapExtraFeeTiers + 1;

        emit UniswapFeeTierAdded(fee);
    }

    /**
     * @notice Updates the oracle price for a pair of tokens, so that calls in the same block don't need to call Uniswap again.
     * @dev This function also checks periodically if there is a better fee tier.
     * @return tickPriceX42 TWAP price of the pair of tokens
     * @return uniswapPoolAddress address of the pool
     */
    function updateOracleState(
        address collateralToken,
        address debtToken
    ) external returns (int64 tickPriceX42, address uniswapPoolAddress) {
        (address token0, address token1) = _orderTokens(collateralToken, debtToken);

        // Get oracle _state
        SirStructs.OracleState memory oracleState = _state[token0][token1];
        if (!oracleState.initialized) revert OracleNotInitialized();

        // Price is updated once per block at most
        if (oracleState.timeStampPrice != block.timestamp) {
            // Update price
            UniswapOracleData memory oracleData = _uniswapOracleData(token0, token1, oracleState.uniswapFeeTier.fee);
            uniswapPoolAddress = address(oracleData.uniswapPool);
            emit UniswapOracleProbed(
                oracleState.uniswapFeeTier.fee,
                oracleData.aggPriceTick,
                oracleData.avLiquidity,
                oracleData.period,
                oracleData.cardinalityToIncrease
            );

            // oracleData.period == 0 is not possible because it would mean the pool is not initialized
            if (oracleData.period == 1) {
                /** If the fee tier has been updated this block
                    AND the cardinality of the selected fee tier is 1,
                    THEN the price is unavailable as TWAP.
                */
                (, int24 tick, , , , , ) = oracleData.uniswapPool.slot0();
                oracleData.aggPriceTick = tick;
            }

            // Updates price and emits event
            bool priceTruncated = _updatePrice(oracleState, oracleData);
            emit PriceUpdated(token0, token1, priceTruncated, oracleState.tickPriceX42);

            // Update timestamp
            oracleState.timeStampPrice = uint40(block.timestamp);

            // Fee tier is updated once per DURATION_UPDATE_FEE_TIER at most
            if (block.timestamp >= oracleState.timeStampFeeTier + DURATION_UPDATE_FEE_TIER) {
                // No OF because timeStampFeeTier is uint40 and constant DURATION_UPDATE_FEE_TIER is a small number
                bool checkCardinalityCurrentFeeTier;
                if (oracleData.period > 0 && oracleState.indexFeeTier != oracleState.indexFeeTierProbeNext) {
                    /** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** /
                     ** ** THIS SECTION PROBES OTHER FEE TIERS IN CASE THEIR PRICE IS MORE RELIABLE THAN THE CURRENT ONE ** ** **
                     ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** ** */

                    // Get current fee tier and the one we wish to probe
                    SirStructs.UniswapFeeTier memory uniswapFeeTierProbed = _uniswapFeeTier(
                        oracleState.indexFeeTierProbeNext
                    );

                    // Retrieve oracle data
                    UniswapOracleData memory oracleDataProbed = _uniswapOracleData(
                        token0,
                        token1,
                        uniswapFeeTierProbed.fee
                    );
                    emit UniswapOracleProbed(
                        uniswapFeeTierProbed.fee,
                        oracleDataProbed.aggPriceTick,
                        oracleDataProbed.avLiquidity,
                        oracleDataProbed.period,
                        oracleDataProbed.cardinalityToIncrease
                    );

                    if (oracleDataProbed.avLiquidity > 0) {
                        /** Compute scores.
                
                            Check the scores for the current fee tier and the probed one.
                            We do now weight the average liquidity by the duration of the TWAP because
                            we do not want to discard fee tiers with short TWAPs.

                            This is different than done in initialize() because a fee tier will not be selected until
                            its average liquidity is the best AND the TWAP is fully initialized.
                        */

                        // oracleData.period == 0 is not possible because it can only happen if the pool is not initialized
                        uint256 score = _feeTierScore(oracleData.avLiquidity, oracleState.uniswapFeeTier);
                        // oracleDataProbed.period == 0 is not possible because it would have filtered out by condition oracleDataProbed.avLiquidity > 0
                        uint256 scoreProbed = _feeTierScore(oracleDataProbed.avLiquidity, uniswapFeeTierProbed);

                        if (scoreProbed > score) {
                            // If the probed fee tier is better than the current one, then we increase its cardinality if necessary
                            if (oracleDataProbed.cardinalityToIncrease > 0) {
                                oracleDataProbed.uniswapPool.increaseObservationCardinalityNext(
                                    oracleDataProbed.cardinalityToIncrease
                                );
                            } else if (oracleDataProbed.period >= TWAP_DURATION) {
                                // If the probed fee tier is better than the current one AND the cardinality is sufficient, switch to the probed tier
                                oracleState.indexFeeTier = oracleState.indexFeeTierProbeNext;
                                emit OracleFeeTierChanged(oracleState.uniswapFeeTier.fee, uniswapFeeTierProbed.fee);
                                oracleState.uniswapFeeTier = uniswapFeeTierProbed;
                                uniswapPoolAddress = address(oracleDataProbed.uniswapPool);
                            }
                        } else {
                            // If the current tier is still better, then we increase its cardinality if necessary
                            checkCardinalityCurrentFeeTier = true;
                        }
                    } else {
                        // If the probed tier is not even initialized, then we increase the cardinality of the current tier if necessary
                        checkCardinalityCurrentFeeTier = true;
                    }
                } else {
                    checkCardinalityCurrentFeeTier = true;
                }

                if (checkCardinalityCurrentFeeTier && oracleData.cardinalityToIncrease > 0) {
                    // We increase the cardinality of the current tier if necessary
                    oracleData.uniswapPool.increaseObservationCardinalityNext(oracleData.cardinalityToIncrease);
                }

                // Point to the next fee tier to probe
                uint numUniswapFeeTiers = 4 + uint8(_uniswapExtraFeeTiers); // Safe because _uniswapExtraFeeTiers's length at most is 5
                oracleState.indexFeeTierProbeNext = (oracleState.indexFeeTierProbeNext + 1) % uint8(numUniswapFeeTiers);

                // Update timestamp
                oracleState.timeStampFeeTier = uint40(block.timestamp);
            }

            // Save new oracle _state to storage
            _state[token0][token1] = oracleState;
        } else {
            uniswapPoolAddress = address(_getUniswapPool(token0, token1, oracleState.uniswapFeeTier.fee));
        }

        // Invert price if necessary
        tickPriceX42 = collateralToken == token1 ? -oracleState.tickPriceX42 : oracleState.tickPriceX42; // Safe to take negative because |tickPriceX42| ≤ MAX_TICK_X42
    }

    /*////////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _uniswapOracleData(
        address token0,
        address token1,
        uint24 fee
    ) private view returns (UniswapOracleData memory oracleData) {
        // Retrieve Uniswap pool
        oracleData.uniswapPool = _getUniswapPool(token0, token1, fee);

        // If pool does not exist, no-op, return all parameters 0.
        if (address(oracleData.uniswapPool).code.length == 0) return oracleData;

        // Retrieve oracle info from Uniswap v3
        uint32[] memory interval = new uint32[](2);
        interval[0] = uint32(TWAP_DURATION);
        interval[1] = 0;
        int56[] memory tickCumulatives;
        uint160[] memory secondsPerLiquidityCumulatives;

        try oracleData.uniswapPool.observe(interval) returns (
            int56[] memory tickCumulatives_,
            uint160[] memory secondsPerLiquidityCumulatives_
        ) {
            tickCumulatives = tickCumulatives_;
            secondsPerLiquidityCumulatives = secondsPerLiquidityCumulatives_;
        } catch Error(string memory reason) {
            // If pool is not initialized (or other unexpected errors), no-op, return all parameters 0.
            if (keccak256(bytes(reason)) != keccak256(bytes("OLD"))) return oracleData;

            /* 
                If Uniswap v3 Pool reverts with the message 'OLD' then
                ...the cardinality of Uniswap v3 oracle is insufficient
                ...or the TWAP storage is not yet filled with price data
             */

            /** About Uni v3 Cardinality
                "cardinalityNow" is the current oracle array length with populated price information
                "cardinalityNext" is the future cardinality
                The oracle array is updated circularly.
                The array's cardinality is not bumped to cardinalityNext until the last element in the array
                (of length cardinalityNow) is updated just before a mint/swap/burn.
             */
            (, , uint16 observationIndex, uint16 cardinalityNow, uint16 cardinalityNext, , ) = oracleData
                .uniswapPool
                .slot0();

            // Get oracle data at the current timestamp
            (tickCumulatives, secondsPerLiquidityCumulatives) = oracleData.uniswapPool.observe(new uint32[](1)); // It should never fail
            int56 tickCumulative_ = tickCumulatives[0];
            uint160 secondsPerLiquidityCumulative_ = secondsPerLiquidityCumulatives[0];

            // Expand arrays to two slots
            tickCumulatives = new int56[](2);
            secondsPerLiquidityCumulatives = new uint160[](2);
            tickCumulatives[1] = tickCumulative_;
            secondsPerLiquidityCumulatives[1] = secondsPerLiquidityCumulative_;

            // Get oracle data for the oldest observation possible
            uint32 blockTimestampOldest;
            {
                bool initialized;
                if (cardinalityNow > 1) {
                    // If cardinalityNow is 1, oldest (and newest) observations are at index 0.
                    (blockTimestampOldest, tickCumulative_, secondsPerLiquidityCumulative_, initialized) = oracleData
                        .uniswapPool
                        .observations((observationIndex + 1) % cardinalityNow);
                    // Safe from OF because observationIndex < cardinalityNow by https://github.com/Uniswap/v3-core/blob/d8b1c635c275d2a9450bd6a78f3fa2484fef73eb/contracts/libraries/Oracle.sol#L99
                }

                /** The next index might not be populated if the cardinality is in the process of increasing.
                    In this case the oldest observation is always in index 0.
                    Observation at index 0 is always initialized.
                */
                if (!initialized) {
                    (blockTimestampOldest, tickCumulative_, secondsPerLiquidityCumulative_, ) = oracleData
                        .uniswapPool
                        .observations(0);
                    cardinalityNow = observationIndex + 1;
                    // The 1st element of observations is always initialized
                }
            }

            // Current TWAP duration
            interval[0] = uint32(block.timestamp - blockTimestampOldest); // Safe because blockTimestampOldest < block.timestamp

            // This can only occur if the fee tier has cardinalityNow 1
            if (interval[0] == 0) {
                // We get the instant liquidity because TWAP liquidity is not available
                oracleData.avLiquidity = oracleData.uniswapPool.liquidity();
                if (oracleData.avLiquidity == 0) oracleData.avLiquidity = 1;
                oracleData.period = 1;
                oracleData.cardinalityToIncrease = 1 + CARDINALITY_DELTA; // No OF because it's a constant
                return oracleData;
            }

            /**
             * Check if cardinality must increase,
             * ...and if so, increment by CARDINALITY_DELTA.
             */
            uint256 cardinalityNeeded = (uint256(cardinalityNow) * TWAP_DURATION - 1) / interval[0] + 1; // Estimate necessary length of the oracle
            if (cardinalityNeeded > cardinalityNext) {
                oracleData.cardinalityToIncrease = cardinalityNext + CARDINALITY_DELTA;
                // OF doesn't matter because it means cardinalityNext is already very close to 2^16
            }

            tickCumulatives[0] = tickCumulative_;
            secondsPerLiquidityCumulatives[0] = secondsPerLiquidityCumulative_;
        }

        // Compute average liquidity which is >=1
        oracleData.avLiquidity = uint136( // Safe conversion because diffSecondsPerLiquidityCumulatives is equal to or greater than interval[0]
            (uint160(interval[0]) << 128) / (secondsPerLiquidityCumulatives[1] - secondsPerLiquidityCumulatives[0])
        ); // It will not divide by 0 because liquidity cumulatives always increase

        // Aggregated price from Uniswap v3 are given as token1/token0
        oracleData.aggPriceTick = tickCumulatives[1] - tickCumulatives[0];

        // Duration of the observation
        oracleData.period = interval[0];
    }

    function _updatePrice(
        SirStructs.OracleState memory oracleState,
        UniswapOracleData memory oracleData
    ) internal view returns (bool truncated) {
        // Compute price (buy operating with int256 we do not need to check for of/uf)
        int256 tickPriceX42 = (int256(oracleData.aggPriceTick) << 42); // Safe because uint56 << 42 < 2^256-1

        /** When period==0, aggPriceTick is in fact the instantaneous price
            When period==1, dividing by period does not change tickPriceX42
        */
        if (oracleData.period > 1) tickPriceX42 /= int256(uint256(oracleData.period));

        if (oracleState.timeStampPrice == 0) oracleState.tickPriceX42 = int64(tickPriceX42);
        else {
            // Truncate price if necessary
            int256 tickMaxIncrement = int256((block.timestamp - oracleState.timeStampPrice)) * MAX_TICK_INC_PER_SEC;
            if (tickPriceX42 > int256(oracleState.tickPriceX42) + tickMaxIncrement) {
                oracleState.tickPriceX42 += int64(tickMaxIncrement); // Cannot OF cuz it is less than tickPriceX42
                truncated = true;
            } else if (tickPriceX42 + tickMaxIncrement < int256(oracleState.tickPriceX42)) {
                oracleState.tickPriceX42 -= int64(tickMaxIncrement); // Cannot UF cuz it is greater than tickPriceX42
                truncated = true;
            } else oracleState.tickPriceX42 = int64(tickPriceX42);
        }
    }

    function _uniswapFeeTier(
        uint8 indexFeeTier
    ) internal view returns (SirStructs.UniswapFeeTier memory uniswapFeeTier) {
        if (indexFeeTier == 0) return SirStructs.UniswapFeeTier(100, 1);
        if (indexFeeTier == 1) return SirStructs.UniswapFeeTier(500, 10);
        if (indexFeeTier == 2) return SirStructs.UniswapFeeTier(3000, 60);
        if (indexFeeTier == 3) return SirStructs.UniswapFeeTier(10000, 200);
        else {
            // Extra fee tiers
            uint uniswapExtraFeeTiers_ = _uniswapExtraFeeTiers;
            uint numUniswapExtraFeeTiers = uint(uint8(uniswapExtraFeeTiers_));
            if (indexFeeTier >= numUniswapExtraFeeTiers + 4) revert UniswapFeeTierIndexOutOfBounds(); // Cannot OF because numUniswapExtraFeeTiers is max 5

            uniswapExtraFeeTiers_ >>= 8 + 48 * (indexFeeTier - 4);
            return SirStructs.UniswapFeeTier(uint24(uniswapExtraFeeTiers_), int24(uint24(uniswapExtraFeeTiers_ >> 24)));
        }
    }

    /**
        The tick TVL (liquidity in Uniswap v3) is a good criteria for selecting the best pool.
        We use the time-weighted tickTVL to score fee tiers.
        However, fee tiers with small weighting period are more susceptible to manipulation.
        Thus, instead we weight the time-weighted tickTVL by the weighting period:
            twTickTVL * period * feeTier = avLiquidity
        
        However, it may be a good idea to weight the score by the fee tier, because it is harder to move the
        price of a pool with higher fee tier.

     */
    function _feeTierScore(
        uint256 aggOrAvLiquidity, // 0 < aggOrAvLiquidity < 2^136
        SirStructs.UniswapFeeTier memory uniswapFeeTier
    ) private pure returns (uint256) {
        // The score is rounded up to ensure it is always >1
        // Safe because (aggOrAvLiquidity*fee)<<72 < 2^(136+24+72) = 2^228
        return (((aggOrAvLiquidity * uniswapFeeTier.fee) << 72) - 1) / uint24(uniswapFeeTier.tickSpacing) + 1;
    }

    function _getUniswapPool(address tokenA, address tokenB, uint24 fee) private view returns (IUniswapV3Pool) {
        return
            IUniswapV3Pool(
                UniswapPoolAddress.computeAddress(UNISWAPV3_FACTORY, UniswapPoolAddress.getPoolKey(tokenA, tokenB, fee))
            );
    }

    function _orderTokens(address tokenA, address tokenB) private pure returns (address, address) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return (tokenA, tokenB);
    }
}
