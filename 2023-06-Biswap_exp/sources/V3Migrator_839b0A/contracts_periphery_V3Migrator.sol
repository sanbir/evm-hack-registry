// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.16;

import '../interfaces/IBiswapPair.sol';
import '../interfaces/ILiquidityManager.sol';
import '../interfaces/IV3Migrator.sol';

import './base/base.sol';

/// @title Biswap V3 Migrator
/// @notice You can use this contract to migrate your V2 liquidity to V3 pool.
contract V3Migrator is Base, IV3Migrator {

    address public immutable liquidityManager;

    int24 fullRangeLength = 800000;

    event Migrate(
        MigrateParams params,
        uint amountRemoved0,
        uint amountRemoved1,
        uint amountAdded0,
        uint amountAdded1
    );

    constructor(
        address _factory,
        address _WETH9,
        address _liquidityManager
    ) Base(_factory, _WETH9) {
        liquidityManager = _liquidityManager;
    }

    /// @inheritdoc IV3Migrator
    function mint(ILiquidityManager.MintParam calldata mintParam) external payable returns(
        uint256 lid,
        uint128 liquidity,
        uint256 amountX,
        uint256 amountY
    ){
        return ILiquidityManager(liquidityManager).mint(mintParam);
    }

    /// @notice This function burn V2 liquidity, and mint V3 liquidity with received tokens
    /// @param params see IV3Migrator.MigrateParams
    /// @return refund0 amount of token0 that burned from V2 but not used to mint V3 liquidity
    /// @return refund1 amount of token1 that burned from V2 but not used to mint V3 liquidity
    function migrate(MigrateParams calldata params) external override returns(uint refund0, uint refund1){

        // burn v2 liquidity to this address
        IBiswapPair(params.pair).transferFrom(params.recipient, params.pair, params.liquidityToMigrate);
        (uint256 amount0V2, uint256 amount1V2) = IBiswapPair(params.pair).burn(address(this));

        // calculate the amounts to migrate to v3
        uint128 amount0V2ToMigrate = uint128(amount0V2);
        uint128 amount1V2ToMigrate = uint128(amount1V2);

        // approve the position manager up to the maximum token amounts
        safeApprove(params.token0, liquidityManager, amount0V2ToMigrate);
        safeApprove(params.token1, liquidityManager, amount1V2ToMigrate);

        // mint v3 position
        (, , uint256 amount0V3, uint256 amount1V3) = ILiquidityManager(liquidityManager).mint(
            ILiquidityManager.MintParam({
                miner: params.recipient,
                tokenX: params.token0,
                tokenY: params.token1,
                fee: params.fee,
                pl: params.tickLower,
                pr: params.tickUpper,
                xLim: amount0V2ToMigrate,
                yLim: amount1V2ToMigrate,
                amountXMin: params.amount0Min,
                amountYMin: params.amount1Min,
                deadline: params.deadline
            })
        );

        // if necessary, clear allowance and refund dust
        if (amount0V3 < amount0V2) {
            if (amount0V3 < amount0V2ToMigrate) {
                safeApprove(params.token0, liquidityManager, 0);
            }

            refund0 = amount0V2 - amount0V3;
            if (params.refundAsETH && params.token0 == WETH9) {
                IWETH9(WETH9).withdraw(refund0);
                safeTransferETH(params.recipient, refund0);
            } else {
                safeTransfer(params.token0, params.recipient, refund0);
            }
        }
        if (amount1V3 < amount1V2) {
            if (amount1V3 < amount1V2ToMigrate) {
                safeApprove(params.token1, liquidityManager, 0);
            }

            refund1 = amount1V2 - amount1V3;
            if (params.refundAsETH && params.token1 == WETH9) {
                IWETH9(WETH9).withdraw(refund1);
                safeTransferETH(params.recipient, refund1);
            } else {
                safeTransfer(params.token1, params.recipient, refund1);
            }
        }

        emit Migrate(
            params,
            amount0V2,
            amount1V2,
            amount0V3,
            amount1V3
        );
    }

    function stretchToPD(int24 point, int24 pd) private pure returns(int24 stretchedPoint){
        if (point < -pd) return ((point / pd) * pd) + pd;
        if (point > pd) return ((point / pd) * pd);
        return 0;
    }

    /// @notice returns maximum possible range in points, used in 'full range' mint variant
    /// @param cp "current point"
    /// @param pd "point delta"
    /// @return pl calculated left point for full range
    /// @return pr calculated right point for full range
    function getFullRangeTicks(int24 cp, int24 pd) public view returns(int24 pl, int24 pr){
        cp = (cp / pd) * pd;
        int24 minPoint = -800000;
        int24 maxPoint = 800000;

        if (cp >= fullRangeLength/2)  return (stretchToPD(maxPoint - fullRangeLength, pd), stretchToPD(maxPoint, pd));
        if (cp <= -fullRangeLength/2) return (stretchToPD(minPoint, pd),  stretchToPD(minPoint + fullRangeLength, pd));
        return (stretchToPD(cp - fullRangeLength/2, pd), stretchToPD(cp + fullRangeLength/2, pd));
    }

    /// @notice returns all requiered info for creating full range position
    /// @param _tokenX target pool tokenX
    /// @param _tokenY target pool tokenY
    /// @param _fee target pool swap fee
    /// @return currentPoint pool current point
    /// @return leftTick calculated left point for full range
    /// @return rightTick calculated right point for full range
    function getPoolState(address _tokenX, address _tokenY, uint16 _fee) public view returns(
        int24 currentPoint,
        int24 leftTick,
        int24 rightTick
    ){
        address poolAddress = pool(_tokenX, _tokenY, _fee);
        (bool success, bytes memory d_state) = poolAddress.staticcall(abi.encodeWithSelector(0xc19d93fb)); //"state()"
        if (!success) revert('pool not created yet!');
        (, bytes memory d_pointDelta) = poolAddress.staticcall(abi.encodeWithSelector(0x58c51ce6)); //"pointDelta()"

        (,currentPoint,,,,,,,,) = abi.decode(d_state, (uint160,int24,uint16,uint16,uint16,bool,uint240,uint16,uint128,uint128));
        (int24 pointDelta) = abi.decode(d_pointDelta, (int24));
        (leftTick, rightTick) = getFullRangeTicks(currentPoint, pointDelta);

        return (currentPoint, leftTick, rightTick);
    }
}
