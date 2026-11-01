// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

abstract contract LiquidityBook {
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    struct Segment {
        int24 upper;
        int24 below;
        int24 above;
        uint128 liquidity;
    }

    struct Spot {
        bool filled;
        int24 lower;
        int24 upper;
        uint128 liquidity;
        int24 below;
        int24 above;
    }

    struct Take {
        int24 lower;
        int24 upper;
        uint128 liquidity;
        int24 cutLower;
        int24 cutUpper;
        int24 partialLower;
        uint128 partialTaken;
    }

    struct Cut {
        int24 lower;
        int24 upper;
        uint104 liquidity;
        uint104 partialTaken;
    }

    struct Profile {
        int24[5] at;
        uint128[4] liquidity;
        uint256 count;
    }

    int24 public constant TICK_SPACING = 10;
    int24 public constant LOWEST_TICK = TickMath.MIN_TICK - (TickMath.MIN_TICK % TICK_SPACING);
    int24 public constant HIGHEST_TICK = TickMath.MAX_TICK - (TickMath.MAX_TICK % TICK_SPACING);
    int24 public constant NONE = type(int24).min;
    uint256 public constant MAX_TAKES = 16;

    IPoolManager public immutable POOL_MANAGER;

    mapping(int24 lower => Segment) public segments;
    int24 public hint = NONE;

    error OutOfRange();

    constructor(IPoolManager manager) {
        POOL_MANAGER = manager;
    }

    function poolKey() public view virtual returns (PoolKey memory);

    function _poolId() internal view virtual returns (PoolId);

    function _sqrtPrice() internal view returns (uint160 sqrtPrice) {
        (sqrtPrice,,,) = POOL_MANAGER.getSlot0(_poolId());
    }

    function _floor(int24 tick) internal pure returns (int24) {
        return tick - (((tick % TICK_SPACING) + TICK_SPACING) % TICK_SPACING);
    }

    function _alignedAtOrBelow(uint160 sqrtPrice) internal pure returns (int24) {
        return _floor(TickMath.getTickAtSqrtPrice(sqrtPrice));
    }

    function _alignedAtOrAbove(uint160 sqrtPrice) internal pure returns (int24 tick) {
        tick = TickMath.getTickAtSqrtPrice(sqrtPrice);
        if (TickMath.getSqrtPriceAtTick(tick) < sqrtPrice) ++tick;
        int24 floored = _floor(tick);
        return floored == tick ? tick : floored + TICK_SPACING;
    }

    function _first(int24 lower, int24 upper, uint128 liquidity) internal {
        _modify(lower, upper, int256(uint256(liquidity)));
        segments[lower] = Segment({upper: upper, below: NONE, above: NONE, liquidity: liquidity});
        hint = lower;
    }

    function _locate(int24 tick, int24 start) internal view returns (Spot memory spot) {
        int24 s = start == NONE ? hint : start;
        if (s == NONE) {
            return Spot({
                filled: false, lower: LOWEST_TICK, upper: HIGHEST_TICK, liquidity: 0, below: NONE, above: NONE
            });
        }
        Segment memory seg = segments[s];
        while (s > tick) {
            if (seg.below == NONE) {
                return
                    Spot({filled: false, lower: LOWEST_TICK, upper: s, liquidity: 0, below: NONE, above: s});
            }
            s = seg.below;
            seg = segments[s];
        }
        while (seg.above != NONE && seg.above <= tick) {
            s = seg.above;
            seg = segments[s];
        }
        if (tick < seg.upper) {
            return Spot({
                filled: true,
                lower: s,
                upper: seg.upper,
                liquidity: seg.liquidity,
                below: seg.below,
                above: seg.above
            });
        }
        return Spot({
            filled: false,
            lower: seg.upper,
            upper: seg.above == NONE ? HIGHEST_TICK : seg.above,
            liquidity: 0,
            below: s,
            above: seg.above
        });
    }

    function _plan(uint256 budget)
        internal
        view
        returns (Take[] memory takes, uint256 count, uint256 cost, uint256 tokens)
    {
        takes = new Take[](MAX_TAKES);
        int24 x = _alignedAtOrBelow(_sqrtPrice());
        int24 cursor = NONE;
        uint256 left = budget;

        while (left != 0 && count < MAX_TAKES && x > LOWEST_TICK) {
            Spot memory spot = _locate(x - 1, cursor);
            if (!spot.filled) {
                if (spot.below == NONE) break;
                cursor = spot.below;
                x = spot.lower;
                continue;
            }
            cursor = spot.lower;

            Take memory t = Take({
                lower: spot.lower,
                upper: spot.upper,
                liquidity: spot.liquidity,
                cutLower: spot.lower,
                cutUpper: x,
                partialLower: spot.lower,
                partialTaken: 0
            });
            (uint256 spent, uint256 got, bool whole) = _fill(t, left);
            left -= spent;
            cost += spent;
            tokens += got;
            if (t.cutUpper > t.cutLower || t.partialTaken != 0) takes[count++] = t;
            if (!whole) break;
            x = spot.lower;
        }
    }

    function _fill(Take memory t, uint256 left)
        private
        pure
        returns (uint256 spent, uint256 got, bool whole)
    {
        uint160 top = TickMath.getSqrtPriceAtTick(t.cutUpper);
        uint160 bottom = TickMath.getSqrtPriceAtTick(t.lower);
        spent = SqrtPriceMath.getAmount0Delta(bottom, top, t.liquidity, true);
        if (spent <= left) {
            return (spent, SqrtPriceMath.getAmount1Delta(bottom, top, t.liquidity, false), true);
        }

        int24 y = _alignedAtOrAbove(
            SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(top, t.liquidity, left, true)
        );
        if (y > t.cutUpper) y = t.cutUpper;
        spent = SqrtPriceMath.getAmount0Delta(TickMath.getSqrtPriceAtTick(y), top, t.liquidity, true);
        while (spent > left) {
            y += TICK_SPACING;
            spent = SqrtPriceMath.getAmount0Delta(TickMath.getSqrtPriceAtTick(y), top, t.liquidity, true);
        }
        got = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(y), top, t.liquidity, false);
        t.cutLower = y;
        t.partialLower = y;

        if (y > t.lower) {
            (uint256 unitSpent, uint256 unitGot) = _fillUnit(t, y, left - spent);
            spent += unitSpent;
            got += unitGot;
        }
    }

    function _fillUnit(Take memory t, int24 top, uint256 left)
        private
        pure
        returns (uint256 spent, uint256 got)
    {
        uint160 high = TickMath.getSqrtPriceAtTick(top);
        uint160 low = TickMath.getSqrtPriceAtTick(top - TICK_SPACING);
        uint128 taken = _liquidityForEth(low, high, left);
        if (taken > t.liquidity) taken = t.liquidity;
        if (taken == 0) return (0, 0);
        t.partialLower = top - TICK_SPACING;
        t.partialTaken = taken;
        spent = SqrtPriceMath.getAmount0Delta(low, high, taken, true);
        got = SqrtPriceMath.getAmount1Delta(low, high, taken, false);
    }

    function _carve(Take memory t) internal {
        Profile memory p;
        _push(p, t.lower, t.partialLower, t.liquidity);
        _push(p, t.partialLower, t.cutLower, t.liquidity - t.partialTaken);
        _push(p, t.cutLower, t.cutUpper, 0);
        _push(p, t.cutUpper, t.upper, t.liquidity);
        _reshape(t.lower, t.upper, t.liquidity, p);
    }

    function _cutOf(Take memory t) internal pure returns (Cut memory) {
        return Cut({
            lower: t.cutLower,
            upper: t.cutUpper,
            liquidity: uint256(t.liquidity).toUint104(),
            partialTaken: uint256(t.partialTaken).toUint104()
        });
    }

    function _span(Cut memory c) internal pure returns (int24 low, int24 high) {
        low = c.partialTaken != 0 ? c.lower - TICK_SPACING : c.lower;
        high = c.upper;
    }

    function _restore(Cut memory c) internal {
        if (c.upper > c.lower) _add(c.lower, c.upper, c.liquidity);
        if (c.partialTaken != 0) _add(c.lower - TICK_SPACING, c.lower, c.partialTaken);
    }

    function _add(int24 lower, int24 upper, uint128 amount) internal {
        if (amount == 0) return;
        if (lower < LOWEST_TICK || upper > HIGHEST_TICK || lower >= upper) revert OutOfRange();
        int24 x = upper;
        while (x > lower) {
            Spot memory spot = _locate(x - 1, NONE);
            int24 from = spot.lower > lower ? spot.lower : lower;
            if (spot.filled) {
                Profile memory p;
                _push(p, spot.lower, from, spot.liquidity);
                _push(p, from, x, spot.liquidity + amount);
                _push(p, x, spot.upper, spot.liquidity);
                _reshape(spot.lower, spot.upper, spot.liquidity, p);
            } else {
                _modify(from, x, int256(uint256(amount)));
                _link(
                    spot.below,
                    from,
                    Segment({upper: x, below: spot.below, above: spot.above, liquidity: amount})
                );
                hint = from;
            }
            x = from;
        }
    }

    function _link(int24 below, int24 lower, Segment memory seg) private {
        segments[lower] = seg;
        if (below != NONE) segments[below].above = lower;
        if (seg.above != NONE) segments[seg.above].below = lower;
    }

    function _push(Profile memory p, int24 from, int24 to, uint128 liquidity) private pure {
        if (from >= to) return;
        if (p.count == 0) p.at[0] = from;
        p.at[p.count + 1] = to;
        p.liquidity[p.count] = liquidity;
        ++p.count;
    }

    function _reshape(int24 lower, int24 upper, uint128 old, Profile memory p) private {
        Segment memory seg = segments[lower];

        if (p.count == 1) {
            uint128 next = p.liquidity[0];
            if (next == old) return;
            _modify(lower, upper, int256(uint256(next)) - int256(uint256(old)));
            if (next != 0) {
                segments[lower].liquidity = next;
                return;
            }
            delete segments[lower];
            if (seg.below != NONE) segments[seg.below].above = seg.above;
            if (seg.above != NONE) segments[seg.above].below = seg.below;
            hint = seg.below != NONE ? seg.below : seg.above;
            return;
        }

        delete segments[lower];
        int24 previous = seg.below;
        for (uint256 i = 0; i < p.count; ++i) {
            uint128 liquidity = p.liquidity[i];
            if (liquidity == 0) continue;
            int24 from = p.at[i];
            _modify(from, p.at[i + 1], int256(uint256(liquidity)));
            segments[from] = Segment({upper: p.at[i + 1], below: previous, above: NONE, liquidity: liquidity});
            if (previous != NONE) segments[previous].above = from;
            previous = from;
        }
        _modify(lower, upper, -int256(uint256(old)));

        if (previous != NONE) segments[previous].above = seg.above;
        if (seg.above != NONE) segments[seg.above].below = previous;
        hint = previous != NONE ? previous : seg.above;
    }

    function _modify(int24 lower, int24 upper, int256 delta) internal {
        POOL_MANAGER.modifyLiquidity(
            poolKey(),
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: delta, salt: 0}),
            ""
        );
    }

    function _liquidityForEth(uint160 bottom, uint160 top, uint256 eth) internal pure returns (uint128) {
        return FullMath.mulDiv(eth, FullMath.mulDiv(bottom, top, FixedPoint96.Q96), top - bottom).toUint128();
    }

    function _liquidityForTokens(uint160 bottom, uint160 top, uint256 tokens)
        internal
        pure
        returns (uint128)
    {
        return FullMath.mulDiv(tokens, FixedPoint96.Q96, top - bottom).toUint128();
    }
}
