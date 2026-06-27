pragma solidity ^0.8.20;

import {SwapMath} from "./SwapMath.sol";
import {TransferHelper} from "Depeg-swap/contracts/libraries/TransferHelper.sol";

struct MarketSnapshot {
    address ra;
    address ct;
    uint256 reserveRa;
    uint256 reserveCt;
    uint256 oneMinusT;
    uint256 baseFee;
    address liquidityToken;
    uint256 startTimestamp;
    uint256 endTimestamp;
    uint256 treasuryFeePercentage;
}

library MarketSnapshotLib {
    function getAmountOut(MarketSnapshot memory self, uint256 amountIn, bool raForCt)
        internal
        view
        returns (uint256 amountOut)
    {
        address tokenIn = raForCt ? self.ra : self.ct;

        amountIn = TransferHelper.tokenNativeDecimalsToFixed(amountIn, tokenIn);

        amountOut = getAmountOutNoConvert(self, amountIn, raForCt);

        address tokenOut = raForCt ? self.ct : self.ra;
        amountOut = TransferHelper.fixedToTokenNativeDecimals(amountOut, self.ct);
    }

    function getAmountOutNoConvert(MarketSnapshot memory self, uint256 amountIn, bool raForCt)
        internal
        view
        returns (uint256 amountOut)
    {
        if (raForCt) {
            (amountOut,) = SwapMath.getAmountOut(amountIn, self.reserveRa, self.reserveCt, self.oneMinusT, self.baseFee);
        } else {
            (amountOut,) = SwapMath.getAmountOut(amountIn, self.reserveCt, self.reserveRa, self.oneMinusT, self.baseFee);
        }
    }

    function getAmountInNoConvert(MarketSnapshot memory self, uint256 amountOut, bool raForCt)
        internal
        view
        returns (uint256 amountIn)
    {
        if (raForCt) {
            (amountIn,) = SwapMath.getAmountIn(amountOut, self.reserveRa, self.reserveCt, self.oneMinusT, self.baseFee);
        } else {
            (amountIn,) = SwapMath.getAmountIn(amountOut, self.reserveCt, self.reserveRa, self.oneMinusT, self.baseFee);
        }
    }

    function getAmountIn(MarketSnapshot memory self, uint256 amountOut, bool raForCt)
        internal
        view
        returns (uint256 amountIn)
    {
        address tokenOut = raForCt ? self.ct : self.ra;
        amountOut = TransferHelper.tokenNativeDecimalsToFixed(amountOut, tokenOut);

        amountOut = getAmountInNoConvert(self, amountOut, raForCt);

        address tokenIn = raForCt ? self.ra : self.ct;
        amountIn = TransferHelper.fixedToTokenNativeDecimals(amountIn, tokenIn);
    }
}
