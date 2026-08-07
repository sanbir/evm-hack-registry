// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {AdminLib} from "Commons/Util/Admin.sol";

import {FeeLib} from "./Fees.sol";
import {FullMath} from "../FullMath.sol";
import {IKodiakIsland} from "./integrations/kodiak/IKodiakIsland.sol";
import {Info} from "../../src/single/Info.sol";
import {IStationProxy} from "./IStationProxy.sol";
import {IUniswapV3Pool} from "./integrations/kodiak/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "./integrations/uniswap/LiquidityAmounts.sol";
import {TransferHelper} from "../TransferHelper.sol";
import {TickMath} from "./integrations/uniswap/TickMath.sol";
import {TickRange} from "./TickRange.sol";

/// @notice A stableswap AMM for a pair of tokens that uses multiple concentrated Uni-V3 positions
/// to replicate a super-set of stableswap math and other swap curves more efficiently than a numeric solution does.
contract Burve is ERC20 {
    uint256 private constant X96_MASK = (1 << 96) - 1;
    uint256 private constant UNIT_NOMINAL_LIQ_X64 = 1 << 64;
    uint256 private constant MIN_DEAD_SHARES = 100;

    /// The v3 pool.
    IUniswapV3Pool public pool;
    /// The pool's token0.
    IERC20 public token0;
    /// The pool's token1.
    IERC20 public token1;
    /// The optional Kodiak island.
    IKodiakIsland public island;
    /// The station proxy.
    IStationProxy public stationProxy;
    /// The n ranges.
    /// If there is an island that range lies at index 0, encoded as (0, 0).
    TickRange[] public ranges;
    /// The relative liquidity for our n ranges.
    /// If there is an island that distribution lies at index 0.
    uint256[] public distX96;
    /// Total nominal liquidity.
    uint128 public totalNominalLiq;
    /// Total shares of nominal liquidity.
    uint256 public totalShares;
    // Total island shares.
    uint256 public totalIslandShares;
    /// Mapping of owner to island shares they own.
    mapping(address owner => uint256 islandShares) public islandSharesPerOwner;

    /// Emitted when shares are minted.
    event Mint(
        address indexed sender,
        address indexed recipient,
        uint256 shares,
        uint256 islandShares
    );
    /// Emitted when shares are burned.
    event Burn(address indexed owner, uint256 shares, uint256 islandShares);
    /// Emitted when the station proxy is migrated.
    event MigrateStationProxy(
        IStationProxy indexed from,
        IStationProxy indexed to
    );
    /// Emitted during compound if calculated nominal liquidity is infinite for both tokens,
    /// indicating a serious problem with the underlying pool or configuration of this contract.
    event MalformedPool();

    /// Thrown if the given tick range does not match the pools tick spacing.
    error InvalidRange(int24 lower, int24 upper);
    /// Thrown if an island is provided without the island range at index 0,
    /// if the island range at index 0 is provided without the island,
    /// or if an island range is given at an index other than 0.
    error InvalidIslandRange();
    /// Thrown if no ranges are provided.
    error NoRanges();
    /// Thrown when the provided island points to a pool that does not match the provided pool.
    error MismatchedIslandPool(address island, address pool);
    /// Thrown when the number of ranges and number of weights do not match.
    error MismatchedRangeWeightLengths(
        uint256 rangeLength,
        uint256 weightLength
    );
    /// If you burn too much liq at once, we can't collect that amount in one call.
    /// Please split up into multiple calls.
    error TooMuchBurnedAtOnce(uint128 liq, uint256 tokens, bool isX);
    /// Thrown during the uniswapV3MintCallback if the msg.sender is not the pool.
    /// Only the uniswap pool has permission to call this.
    error UniswapV3MintCallbackSenderNotPool(address sender);
    /// Thrown if the price of the pool has moved outside the accepted range during mint / burn.
    error SqrtPriceX96OverLimit(
        uint160 sqrtPriceX96,
        uint160 lowerSqrtPriceLimitX96,
        uint160 upperSqrtPriceLimitX96
    );
    /// Thrown if trying to migrate to the same station proxy.
    error MigrateToSameStationProxy();
    /// Thrown when the first mint is insufficient.
    error InsecureFirstMintAmount(uint256 shares);
    /// Thrown when the first mint is not deadshares.
    error InsecureFirstMintRecipient(address recipient);

    /// Modifier used to ensure the price of the pool is within the accepted lower and upper limits. When minting / burning.
    modifier withinSqrtPX96Limits(
        uint160 lowerSqrtPriceLimitX96,
        uint160 upperSqrtPriceLimitX96
    ) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        if (
            sqrtRatioX96 < lowerSqrtPriceLimitX96 ||
            sqrtRatioX96 > upperSqrtPriceLimitX96
        ) {
            revert SqrtPriceX96OverLimit(
                sqrtRatioX96,
                lowerSqrtPriceLimitX96,
                upperSqrtPriceLimitX96
            );
        }

        _;
    }

    /// @param _pool The pool we are wrapping
    /// @param _island The optional island we are wrapping
    /// @param _ranges the n ranges
    /// @param _weights n weights defining the relative liquidity for each range.
    constructor(
        address _pool,
        address _island,
        address _stationProxy,
        TickRange[] memory _ranges,
        uint128[] memory _weights
    ) ERC20(nameFromPool(_pool), symbolFromPool(_pool)) {
        AdminLib.initOwner(msg.sender);

        pool = IUniswapV3Pool(_pool);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());

        island = IKodiakIsland(_island);
        stationProxy = IStationProxy(_stationProxy);

        bool hasIsland = (_island != address(0x0));
        if (hasIsland && address(island.pool()) != _pool) {
            revert MismatchedIslandPool(_island, _pool);
        }

        if (_ranges.length != _weights.length) {
            revert MismatchedRangeWeightLengths(
                _ranges.length,
                _weights.length
            );
        }

        if (_ranges.length == 0) {
            revert NoRanges();
        }

        uint256 rangeIndex = 0;

        // copy optional island range to storage
        if (hasIsland) {
            TickRange memory range = _ranges[rangeIndex];
            if (!range.isIsland()) revert InvalidIslandRange();
            ranges.push(range);
            ++rangeIndex;
        }

        // copy v3 ranges to storage
        int24 tickSpacing = pool.tickSpacing();
        while (rangeIndex < _ranges.length) {
            TickRange memory range = _ranges[rangeIndex];

            if (range.isIsland()) {
                revert InvalidIslandRange();
            }

            if (
                (range.lower % tickSpacing != 0) ||
                (range.upper % tickSpacing != 0)
            ) {
                revert InvalidRange(range.lower, range.upper);
            }

            ranges.push(range);
            ++rangeIndex;
        }

        // compute total sum of weights
        uint256 sum = 0;
        for (uint256 i = 0; i < _weights.length; ++i) {
            sum += _weights[i];
        }

        // calculate distribution for each weighted position
        for (uint256 i = 0; i < _weights.length; ++i) {
            distX96.push((_weights[i] << 96) / sum);
        }

        // Now that the pool is constructed, remember the first mint
        // must be a minimum of 100 deadshares sent to this contract.
    }

    /// @notice Allows the owner to migrate to a new station proxy.
    /// @param newStationProxy The new station proxy to migrate to.
    function migrateStationProxy(IStationProxy newStationProxy) external {
        AdminLib.validateOwner();

        if (address(stationProxy) == address(newStationProxy)) {
            revert MigrateToSameStationProxy();
        }

        emit MigrateStationProxy(stationProxy, newStationProxy);

        stationProxy.migrate(newStationProxy);
        stationProxy = newStationProxy;
    }

    /// @notice mints liquidity for the recipient
    /// @param recipient The recipient of the minted liquidity.
    /// @param mintNominalLiq The amount of nominal liquidity to mint.
    /// @param lowerSqrtPriceLimitX96 The lower price limit of the pool.
    /// @param upperSqrtPriceLimitX96 The upper price limit of the pool.
    function mint(
        address recipient,
        uint128 mintNominalLiq,
        uint160 lowerSqrtPriceLimitX96,
        uint160 upperSqrtPriceLimitX96
    )
        public
        withinSqrtPX96Limits(lowerSqrtPriceLimitX96, upperSqrtPriceLimitX96)
        returns (uint256 shares)
    {
        // compound v3 ranges
        compoundV3Ranges();

        uint256 islandShares = 0;

        // mint liquidity for each range
        for (uint256 i = 0; i < distX96.length; ++i) {
            uint128 liqInRange = uint128(
                shift96(uint256(mintNominalLiq) * distX96[i], true)
            );

            if (liqInRange == 0) {
                continue;
            }

            TickRange memory range = ranges[i];
            if (range.isIsland()) {
                islandShares = mintIsland(recipient, liqInRange);
            } else {
                // mint the V3 ranges
                pool.mint(
                    address(this),
                    range.lower,
                    range.upper,
                    liqInRange,
                    abi.encode(msg.sender)
                );
            }
        }

        // calculate shares to mint
        if (totalShares == 0) {
            // If this is the first mint, it has to be dead shares, burned by giving it to this contract.
            shares = mintNominalLiq;
            if (shares < MIN_DEAD_SHARES)
                revert InsecureFirstMintAmount(shares);
            if (recipient != address(this))
                revert InsecureFirstMintRecipient(recipient);
        } else {
            shares = FullMath.mulDiv(
                mintNominalLiq,
                totalShares,
                totalNominalLiq
            );
        }

        // adjust total nominal liquidity
        totalNominalLiq += mintNominalLiq;

        // mint shares
        totalShares += shares;
        _mint(recipient, shares);

        emit Mint(msg.sender, recipient, shares, islandShares);
    }

    /// @notice Mints to the island.
    /// @param recipient The recipient of the minted liquidity.
    /// @param liq The amount of liquidity to mint.
    /// @return mintIslandShares The amount of island shares minted.
    function mintIsland(
        address recipient,
        uint128 liq
    ) internal returns (uint256 mintIslandShares) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

        (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
            sqrtRatioX96,
            liq,
            island.lowerTick(),
            island.upperTick(),
            true
        );
        (uint256 mint0, uint256 mint1, uint256 mintShares) = island
            .getMintAmounts(amount0, amount1);

        islandSharesPerOwner[recipient] += mintShares;
        totalIslandShares += mintShares;

        // transfer required tokens to this contract
        TransferHelper.safeTransferFrom(
            address(token0),
            msg.sender,
            address(this),
            mint0
        );
        TransferHelper.safeTransferFrom(
            address(token1),
            msg.sender,
            address(this),
            mint1
        );

        // approve transfer to the island
        SafeERC20.forceApprove(token0, address(island), amount0);
        SafeERC20.forceApprove(token1, address(island), amount1);

        island.mint(mintShares, address(this));

        SafeERC20.forceApprove(token0, address(island), 0);
        SafeERC20.forceApprove(token1, address(island), 0);

        // deposit minted shares to the station proxy
        SafeERC20.forceApprove(island, address(stationProxy), mintShares);
        stationProxy.depositLP(address(island), mintShares, recipient);
        SafeERC20.forceApprove(island, address(stationProxy), 0);

        return mintShares;
    }

    /// @notice burns liquidity for the msg.sender
    /// @param shares The amount of Burve LP token to burn.
    /// @param lowerSqrtPriceLimitX96 The lower price limit of the pool.
    /// @param upperSqrtPriceLimitX96 The upper price limit of the pool.
    function burn(
        uint256 shares,
        uint160 lowerSqrtPriceLimitX96,
        uint160 upperSqrtPriceLimitX96
    )
        external
        withinSqrtPX96Limits(lowerSqrtPriceLimitX96, upperSqrtPriceLimitX96)
    {
        // compound v3 ranges
        compoundV3Ranges();

        uint128 burnLiqNominal = uint128(
            FullMath.mulDiv(shares, uint256(totalNominalLiq), totalShares)
        );

        // adjust total nominal liquidity
        totalNominalLiq -= burnLiqNominal;

        uint256 priorBalance0 = token0.balanceOf(address(this));
        uint256 priorBalance1 = token1.balanceOf(address(this));

        uint256 islandShares = 0;

        // burn liquidity for each range
        for (uint256 i = 0; i < distX96.length; ++i) {
            TickRange memory range = ranges[i];
            if (range.isIsland()) {
                islandShares = burnIsland(shares);
            } else {
                uint128 liqInRange = uint128(
                    shift96(uint256(burnLiqNominal) * distX96[i], false)
                );
                if (liqInRange > 0) {
                    burnV3(range, liqInRange);
                }
            }
        }

        // burn shares
        totalShares -= shares;
        _burn(msg.sender, shares);

        // transfer collected tokens to msg.sender
        uint256 postBalance0 = token0.balanceOf(address(this));
        uint256 postBalance1 = token1.balanceOf(address(this));
        TransferHelper.safeTransfer(
            address(token0),
            msg.sender,
            postBalance0 - priorBalance0
        );
        TransferHelper.safeTransfer(
            address(token1),
            msg.sender,
            postBalance1 - priorBalance1
        );

        emit Burn(msg.sender, shares, islandShares);
    }

    /// @notice Burns share of the island on behalf of msg.sender.
    /// @param shares The amount of Burve LP token to burn.
    /// @return islandBurnShares The amount of island shares burned.
    function burnIsland(
        uint256 shares
    ) internal returns (uint256 islandBurnShares) {
        // calculate island shares to burn
        islandBurnShares = FullMath.mulDiv(
            islandSharesPerOwner[msg.sender],
            shares,
            balanceOf(msg.sender)
        );

        if (islandBurnShares == 0) {
            return 0;
        }

        islandSharesPerOwner[msg.sender] -= islandBurnShares;
        totalIslandShares -= islandBurnShares;

        // withdraw burn shares from the station proxy
        stationProxy.withdrawLP(address(island), islandBurnShares, msg.sender);
        island.burn(islandBurnShares, address(this));
    }

    /// @notice Burns liquidity for a v3 range.
    /// @param range The range to burn.
    /// @param liq The amount of liquidity to burn.
    function burnV3(TickRange memory range, uint128 liq) internal {
        (uint256 x, uint256 y) = pool.burn(range.lower, range.upper, liq);

        if (x > type(uint128).max) revert TooMuchBurnedAtOnce(liq, x, true);
        if (y > type(uint128).max) revert TooMuchBurnedAtOnce(liq, y, false);

        pool.collect(
            address(this),
            range.lower,
            range.upper,
            uint128(x),
            uint128(y)
        );
    }

    /// @notice Queries the token amounts in a user's position.
    /// @dev As of now, this method is only used by off-chain queries where the minor errors are negligible. Do not use this where high-precision is required.
    /// @param owner The owner of the position.
    /// @return query0 The amount of token 0.
    /// @return query1 The amount of token 1.
    function queryValue(
        address owner
    ) external view returns (uint256 query0, uint256 query1) {
        // calculate amounts owned in v3 ranges
        uint256 shares = balanceOf(owner);
        (query0, query1) = queryValueV3Ranges(shares);

        // calculate amounts owned by island position
        uint256 ownerIslandShares = islandSharesPerOwner[owner];
        (uint256 island0, uint256 island1) = queryValueIsland(
            ownerIslandShares
        );
        query0 += island0;
        query1 += island1;
    }

    /// @notice Queries the token amounts held by the contract. Ignoring leftover amounts.
    /// @dev As of now, this method is only used by off-chain queries where the minor errors are negligible. Do not use this where high-precision is required.
    /// @return query0 The amount of token 0.
    /// @return query1 The amount of token 1.
    function queryTVL() external view returns (uint256 query0, uint256 query1) {
        // calculate amounts owned in v3 ranges
        (query0, query1) = queryValueV3Ranges(totalShares);

        // calculate amounts owned by island position
        (uint256 island0, uint256 island1) = queryValueIsland(
            totalIslandShares
        );
        query0 += island0;
        query1 += island1;
    }

    /// @notice Queries amounts in the island by simulating a burn.
    /// @dev As of now, this method is only used by off-chain queries where the minor errors are negligible. Do not use this where high-precision is required.
    /// @param islandShares Island shares.
    /// @return query0 The amount of token 0.
    /// @return query1 The amount of token 1.
    function queryValueIsland(
        uint256 islandShares
    ) public view returns (uint256 query0, uint256 query1) {
        if (islandShares == 0) {
            return (0, 0);
        }

        int24 lower = island.lowerTick();
        int24 upper = island.upperTick();
        uint256 totalSupply = island.totalSupply();

        (uint160 sqrtRatioX96, int24 tick, , , , , ) = pool.slot0();

        // get island position id
        bytes32 positionId = keccak256(
            abi.encodePacked(address(island), lower, upper)
        );

        // lookup island position
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint256 tokensOwed0,
            uint256 tokensOwed1
        ) = pool.positions(positionId);

        // calculate accumulated fees
        (uint256 fees0, uint256 fees1) = FeeLib.viewAccumulatedFees(
            pool,
            lower,
            upper,
            tick,
            liquidity,
            feeGrowthInside0LastX128,
            feeGrowthInside1LastX128
        );
        fees0 += tokensOwed0;
        fees1 += tokensOwed1;

        // subtract manager fee
        (fees0, fees1) = subtractManagerFee(
            fees0,
            fees1,
            island.managerFeeBPS()
        );

        // get amounts for burned liquidity
        uint128 burnedLiq = uint128(
            FullMath.mulDiv(liquidity, islandShares, totalSupply)
        );
        (query0, query1) = getAmountsForLiquidity(
            sqrtRatioX96,
            burnedLiq,
            lower,
            upper,
            false
        );

        // award share of fees
        query0 += FullMath.mulDiv(
            fees0 +
                token0.balanceOf(address(island)) -
                island.managerBalance0(),
            islandShares,
            totalSupply
        );
        query1 += FullMath.mulDiv(
            fees1 +
                token1.balanceOf(address(island)) -
                island.managerBalance1(),
            islandShares,
            totalSupply
        );
    }

    /// @notice Queries amounts in the v3 ranges by simulating burns.
    /// @dev As of now, this method is only used by off-chain queries where the minor errors are negligible. Do not use this where high-precision is required.
    /// @param shares The amount of Burve LP token.
    /// @return query0 The amount of token 0.
    /// @return query1 The amount of token 1.
    function queryValueV3Ranges(
        uint256 shares
    ) public view returns (uint256 query0, uint256 query1) {
        if (shares == 0) {
            return (0, 0);
        }

        (uint160 sqrtRatioX96, int24 tick, , , , , ) = pool.slot0();

        uint256 accumulatedFees0 = 0;
        uint256 accumulatedFees1 = 0;

        uint128 burnLiqNominal = uint128(
            FullMath.mulDiv(shares, uint256(totalNominalLiq), totalShares)
        );

        // accumulate total token amounts in the v3 ranges owned by this contract
        for (uint256 i = 0; i < distX96.length; ++i) {
            TickRange memory range = ranges[i];
            if (range.isIsland()) {
                continue;
            }

            // get v3 position id
            bytes32 positionId = keccak256(
                abi.encodePacked(address(this), range.lower, range.upper)
            );

            // lookup v3 position
            // owed tokens will be 0 due to compounding
            (
                uint128 liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                ,

            ) = pool.positions(positionId);

            // calculate accumulated fees that would be compounded
            // some amount of tokens will remain on the contract as leftovers because they can't be compounded into a unit of liquidity
            // uncompounded tokens remain on the contract instead of going to the user
            (uint128 fees0, uint128 fees1) = FeeLib.viewAccumulatedFees(
                pool,
                range.lower,
                range.upper,
                tick,
                liquidity,
                feeGrowthInside0LastX128,
                feeGrowthInside1LastX128
            );
            uint128 liqInFees = getLiquidityForAmounts(
                sqrtRatioX96,
                fees0,
                fees1,
                range.lower,
                range.upper
            );
            (
                uint256 compoundedFees0,
                uint256 compoundedFees1
            ) = getAmountsForLiquidity(
                    sqrtRatioX96,
                    liqInFees,
                    range.lower,
                    range.upper,
                    false
                );

            accumulatedFees0 += compoundedFees0;
            accumulatedFees1 += compoundedFees1;

            // get amounts for burned liquidity
            uint128 liqInRange = uint128(
                shift96(uint256(burnLiqNominal) * distX96[i], false)
            );
            (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
                sqrtRatioX96,
                liqInRange,
                range.lower,
                range.upper,
                false
            );
            query0 += amount0;
            query1 += amount1;
        }

        // matches collected amount adjustment in collectAndCalcCompound
        if (accumulatedFees0 > distX96.length) {
            accumulatedFees0 -= distX96.length;
        } else {
            accumulatedFees0 = 0;
        }

        if (accumulatedFees1 > distX96.length) {
            accumulatedFees1 -= distX96.length;
        } else {
            accumulatedFees1 = 0;
        }

        // calculate share of accumulated fees
        if (accumulatedFees0 > 0) {
            query0 += FullMath.mulDiv(accumulatedFees0, shares, totalShares);
        }
        if (accumulatedFees1 > 0) {
            query1 += FullMath.mulDiv(accumulatedFees1, shares, totalShares);
        }
    }

    /// @notice Returns info about the contract.
    /// @return info The info struct.
    function getInfo() external view returns (Info memory info) {
        info.pool = pool;
        info.token0 = token0;
        info.token1 = token1;
        info.island = island;
        info.stationProxy = stationProxy;
        info.totalNominalLiq = totalNominalLiq;
        info.totalShares = totalShares;
        info.ranges = ranges;
        info.distX96 = distX96;
    }

    /* Internal Calls */

    /// Override the erc20 update function to handle island share and lp token moves.
    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        // We handle mints and burns in their respective calls.
        // We just want to handle transfers between two valid addresses.
        if (
            from != address(0) &&
            to != address(0) &&
            address(island) != address(0)
        ) {
            // Move the island shares that correspond to the LP tokens being moved.
            uint256 islandTransfer = FullMath.mulDiv(
                islandSharesPerOwner[from],
                value,
                balanceOf(from)
            );

            islandSharesPerOwner[from] -= islandTransfer;
            // It doesn't matter if this is off by one because the user gets a percent of their island shares on burn.
            islandSharesPerOwner[to] += islandTransfer;
            // We withdraw from the station proxy so the burve earnings stop,
            // but the current owner can collect their earnings so far.
            stationProxy.withdrawLP(address(island), islandTransfer, from);

            SafeERC20.forceApprove(
                island,
                address(stationProxy),
                islandTransfer
            );
            stationProxy.depositLP(address(island), islandTransfer, to);
            SafeERC20.forceApprove(island, address(stationProxy), 0);
        }

        super._update(from, to, value);
    }

    /// @notice Collect fees and compound them for each v3 range.
    function compoundV3Ranges() internal {
        // collect fees
        collectV3Fees();

        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

        uint128 compoundedNominalLiq = collectAndCalcCompound();
        if (compoundedNominalLiq == 0) {
            return;
        }

        totalNominalLiq += compoundedNominalLiq;

        // calculate liq and mint amounts
        uint256 totalMint0 = 0;
        uint256 totalMint1 = 0;

        TickRange[] memory memRanges = ranges;
        uint128[] memory compoundLiqs = new uint128[](distX96.length);

        for (uint256 i = 0; i < distX96.length; ++i) {
            TickRange memory range = memRanges[i];

            if (range.isIsland()) {
                continue;
            }

            uint128 compoundLiq = uint128(
                shift96(uint256(compoundedNominalLiq) * distX96[i], true)
            );
            compoundLiqs[i] = compoundLiq;

            if (compoundLiq == 0) {
                continue;
            }

            (uint256 mint0, uint256 mint1) = getAmountsForLiquidity(
                sqrtRatioX96,
                compoundLiq,
                range.lower,
                range.upper,
                true
            );
            totalMint0 += mint0;
            totalMint1 += mint1;
        }

        // approve mints
        SafeERC20.forceApprove(token0, address(this), totalMint0);
        SafeERC20.forceApprove(token1, address(this), totalMint1);

        // mint to each range
        for (uint256 i = 0; i < distX96.length; ++i) {
            TickRange memory range = memRanges[i];

            if (range.isIsland()) {
                continue;
            }

            uint128 compoundLiq = compoundLiqs[i];
            if (compoundLiq == 0) {
                continue;
            }

            pool.mint(
                address(this),
                range.lower,
                range.upper,
                compoundLiq,
                abi.encode(address(this))
            );
        }

        // reset approvals
        SafeERC20.forceApprove(token0, address(this), 0);
        SafeERC20.forceApprove(token1, address(this), 0);
    }

    /* Callbacks */

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        if (msg.sender != address(pool)) {
            revert UniswapV3MintCallbackSenderNotPool(msg.sender);
        }

        address source = abi.decode(data, (address));
        TransferHelper.safeTransferFrom(
            address(token0),
            source,
            address(pool),
            amount0Owed
        );
        TransferHelper.safeTransferFrom(
            address(token1),
            source,
            address(pool),
            amount1Owed
        );
    }

    /* internal helpers */

    /// @notice Calculates nominal compound liq for the collected token amounts.
    /// @dev Collected amounts are limited to a max of type(uint192).max and
    ///      computed liquidity is limited to a max of type(uint128).max.
    function collectAndCalcCompound()
        internal
        returns (uint128 mintNominalLiq)
    {
        // collected amounts on the contract from: fees, compounded leftovers, or tokens sent to the contract.
        uint256 collected0 = token0.balanceOf(address(this));
        uint256 collected1 = token1.balanceOf(address(this));

        // If we collect more than 2^196 in fees, the problem is with the token.
        // If it was worth any meaningful value the world economy would be in the contract.
        // In this case we compound the maximum allowed such that the contract can still operate.
        if (collected0 > type(uint192).max) {
            collected0 = uint256(type(uint192).max);
        }
        if (collected1 > type(uint192).max) {
            collected1 = uint256(type(uint192).max);
        }

        // when split into n ranges the amount of tokens required can be rounded up
        // we need to make sure the collected amount allows for this rounding
        if (collected0 > distX96.length) {
            collected0 -= distX96.length;
        } else {
            collected0 = 0;
        }

        if (collected1 > distX96.length) {
            collected1 -= distX96.length;
        } else {
            collected1 = 0;
        }

        if (collected0 == 0 && collected1 == 0) {
            return 0;
        }

        // compute liq in collected amounts
        (
            uint256 amount0InUnitLiqX64,
            uint256 amount1InUnitLiqX64
        ) = getCompoundAmountsPerUnitNominalLiqX64();

        uint256 nominalLiq0 = amount0InUnitLiqX64 > 0
            ? (collected0 << 64) / amount0InUnitLiqX64
            : uint256(type(uint128).max);
        uint256 nominalLiq1 = amount1InUnitLiqX64 > 0
            ? (collected1 << 64) / amount1InUnitLiqX64
            : uint256(type(uint128).max);

        uint256 unsafeNominalLiq = nominalLiq0 < nominalLiq1
            ? nominalLiq0
            : nominalLiq1;

        // We should never be able to compound infinite liquidity into both tokens at once, either
        // 1) the contract was misconfigured and only consists of a single island or
        // 2) there is something seriously broken with the underlying v3 pool
        // In either case this event serves as a warning.
        // We don't revert because that would block calls to mint / burn.
        if (unsafeNominalLiq == uint256(type(uint128).max)) {
            emit MalformedPool();
        }

        // min calculated liquidity with the max allowed
        mintNominalLiq = unsafeNominalLiq > type(uint128).max
            ? type(uint128).max
            : uint128(unsafeNominalLiq);

        // during mint the liq at each range is rounded up
        // we subtract by the number of ranges to ensure we have enough liq
        mintNominalLiq = mintNominalLiq <= (2 * distX96.length)
            ? 0
            : mintNominalLiq - uint128(2 * distX96.length);
    }

    /// @notice Calculates token amounts needed for compounding one X64 unit of nominal liquidity in the v3 ranges.
    /// @dev The liquidity distribution at each range is rounded up.
    function getCompoundAmountsPerUnitNominalLiqX64()
        internal
        view
        returns (uint256 amount0InUnitLiqX64, uint256 amount1InUnitLiqX64)
    {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

        for (uint256 i = 0; i < distX96.length; ++i) {
            TickRange memory range = ranges[i];

            // skip the island
            if (range.isIsland()) {
                continue;
            }

            // calculate amount of tokens in unit of liquidity X64
            uint128 liqInRangeX64 = uint128(
                shift96(uint256(UNIT_NOMINAL_LIQ_X64) * distX96[i], true)
            );
            (
                uint256 range0InUnitLiqX64,
                uint256 range1InUnitLiqX64
            ) = getAmountsForLiquidity(
                    sqrtRatioX96,
                    liqInRangeX64,
                    range.lower,
                    range.upper,
                    true
                );
            amount0InUnitLiqX64 += range0InUnitLiqX64;
            amount1InUnitLiqX64 += range1InUnitLiqX64;
        }
    }

    /// @notice Collects all earned fees for each v3 range.
    function collectV3Fees() internal {
        for (uint256 i = 0; i < distX96.length; ++i) {
            TickRange memory range = ranges[i];

            uint128 liqInRange = uint128(
                shift96(uint256(totalNominalLiq) * distX96[i], true)
            );

            if (liqInRange == 0) {
                continue;
            }

            // skip islands
            if (range.isIsland()) {
                continue;
            }

            // collect fees
            // call to burn is required for uniswap internals to have proper bookkeeping (tokensOwed to be updated)
            pool.burn(range.lower, range.upper, 0);
            pool.collect(
                address(this),
                range.lower,
                range.upper,
                type(uint128).max,
                type(uint128).max
            );
        }
    }

    /// @notice Calculate token amounts in liquidity for the given range.
    /// @param sqrtRatioX96 The current sqrt ratio of the pool.
    /// @param liquidity The amount of liquidity.
    /// @param lower The lower tick of the range.
    /// @param upper The upper tick of the range.
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint128 liquidity,
        int24 lower,
        int24 upper,
        bool roundUp
    ) private pure returns (uint256 amount0, uint256 amount1) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upper);

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity,
            roundUp
        );
    }

    /// @notice Calculate liquidity amount in given tokens.
    /// @dev Calculated liq is rounded down.
    /// @param sqrtRatioX96 The current sqrt ratio of the pool.
    /// @param amount0 The amount of token 0.
    /// @param amount1 The amount of token 1.
    /// @param lower The lower tick of the range.
    /// @param upper The upper tick of the range.
    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint256 amount0,
        uint256 amount1,
        int24 lower,
        int24 upper
    ) private pure returns (uint128 liq) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upper);

        liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtRatioX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            amount0,
            amount1
        );
    }

    /// @notice Subtract manager fee from the earned fee.
    /// @param _fee0 The earned fee amount of token 0.
    /// @param _fee1 The earned fee amount of token 1.
    /// @param _managerFeeBPS The manager fee in basis points.
    /// @return fee0 The earned fee minus manager fee for token 0.
    /// @return fee1 The earned fee minus manager fee for token 1.
    function subtractManagerFee(
        uint256 _fee0,
        uint256 _fee1,
        uint16 _managerFeeBPS
    ) private pure returns (uint256 fee0, uint256 fee1) {
        fee0 = _fee0 - (_fee0 * _managerFeeBPS) / 10000;
        fee1 = _fee1 - (_fee1 * _managerFeeBPS) / 10000;
    }

    function shift96(uint256 a, bool roundUp) private pure returns (uint256 b) {
        b = a >> 96;
        if (roundUp && (a & X96_MASK) > 0) b += 1;
    }

    /// @notice Computes the name for the ERC20 token given the pool address.
    /// @param _pool The pool address.
    /// @return name The name of the ERC20 token.
    function nameFromPool(
        address _pool
    ) private view returns (string memory name) {
        address t0 = IUniswapV3Pool(_pool).token0();
        address t1 = IUniswapV3Pool(_pool).token1();
        name = string.concat(
            ERC20(t0).name(),
            "-",
            ERC20(t1).name(),
            "-Stable-KodiakLP"
        );
    }

    /// @notice Computes the symbol for the ERC20 token given the pool address.
    /// @param _pool The pool address.
    /// @return sym The symbol of the ERC20 token.
    function symbolFromPool(
        address _pool
    ) private view returns (string memory sym) {
        address t0 = IUniswapV3Pool(_pool).token0();
        address t1 = IUniswapV3Pool(_pool).token1();
        sym = string.concat(
            ERC20(t0).symbol(),
            "-",
            ERC20(t1).symbol(),
            "-SLP-KDK"
        );
    }
}
