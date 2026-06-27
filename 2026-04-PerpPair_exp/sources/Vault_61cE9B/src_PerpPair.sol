// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./perpModules/perpLiquidation.sol";
import "./util/UtilMath.sol";

/**
   In the contract several error codes are present, here is a table of these errors' descriptions.
    | Code | File | Description |
    |------|------|-------------|
    | SET1 | `PerpPair.sol` | Fee fractions (`feeFrontend + feeLP`) not less than `feeFractionsDecimals`. |
    | SET2 | `PerpPair.sol` | Oracle address is zero. |
    | SET3 | `PerpPair.sol` | Vault address is zero. |
    | SET4 | `PerpPair.sol` | MMR is negative. |
    | SET5 | `PerpPair.sol` | Trading fee out of valid range `[0, tradingFeeDecimals)`. |
    | SET6 | `PerpPair.sol` | Flat trading fee too large relative to `minimumTradeSize` and proportional fee. |
    | SET7 | `PerpPair.sol` | Fee protocol address is zero. |
    | T0  | `perpTrade.sol` | Leverage exceeds `maxLeverage`. |
    | T1  | `perpTrade.sol` | User margin ratio after opening trade not above `MMR`. |
    | T2  | `perpTrade.sol` | Trade size below `minimumTradeSize` (value-adjusted for direction). |
    | T3  | `perpTrade.sol` | Insufficient global liquidity (both sides must be ≥ 1e18 notional). |
    | T4  | `perpTrade.sol` | Slippage bounds violated (return < `minTradeReturn` or > `zeroSlippageReturn`). |
    | T5  | `perpTrade.sol` | Trade output exceeds available opposing-side liquidity. |
    | C0  | `perpTrade.sol` | Residual asset exposure after full close exceeds dust threshold (1e10 in value). |
    | C1  | `perpTrade.sol`, `perpLiquidity.sol` | User in bad debt — cannot self-close positions or add/remove liquidity. |
    | L1  | `perpLiquidity.sol` | Add-liquidity amount below `minimumLiquidityMovement`. |
    | L2  | `perpLiquidity.sol` | Deposit fee exceeds user's `maxFeeValue` (when non-zero). |
    | L3  | `perpLiquidity.sol` | LP post-deposit leverage would exceed `maxLpLeverage`. |
    | L4  | `perpLiquidity.sol` | Remove-liquidity amount below `minimumLiquidityMovement`. |
    | L5  | `perpLiquidity.sol` | User attempting to remove more liquidity than they own. |
    | L6  | `perpLiquidity.sol` | Removal fee exceeds user's `maxFeeValue` (when non-zero). |
    | R1  | `internalPerpLogic.sol` | User in bad debt (internal rebalance/PnL guard). |
    | C   | `perpConfig.sol` | Timelock not expired or param hash mismatch on locked parameter update. |
    | F1  | `perpFunding.sol` | Funding rate timestamp is in the future. |
    | A   | `perpAutoClose.sol` | Enabling auto-close without setting any threshold (profit or loss). |
    | A1  | `perpAutoClose.sol` | Auto-close attempt failed: user not authorized, or relevant threshold unset/not reached. |
    | LQ1 | `perpLiquidation.sol` | Liquidation fraction exceeds 100 % (full) or 50 % (partial). |
    | LQ2 | `perpLiquidation.sol` | Liquidator's own margin ratio not above `MMR` after liquidation. |
 */
contract PerpPair is PerpLiquidation {
    using Math for uint256;
    using SignedMath for int256;

    constructor(
        address _oracle,
        address _vault,
        address _multiCallManager,
        uint256 _MMR,
        bytes32 _tickerAssetCurrency,
        uint32 _feeFrontend,
        uint32 _feeLP,
        address _feeProtocolAddr,
        uint256 _tradingFee,
        uint256 _flatTradingFee,
        uint256 _emaParam
    ) ERC2771Context(_multiCallManager) {
        decimals = Decimals(1e6,1e6,1e6,1e10,1e18,1e5,SafeCast.toInt256(1e22), 1e18, 1e24);
        curveParameters = CurveParameters(1*1e8, 1*1e7, 1*1e8, 1*1e7, 0, 6, true, 0);
        clampParameters = UtilMath.ClampParameters(0,1e18,0);
        require(_oracle != address(0), "SET2");
        oracle = _oracle;
        require(_vault != address(0), "SET3");
        vault = _vault;
        require(_MMR >= 0, "SET4");
        MMR = _MMR;
        tickerAssetCurrency = _tickerAssetCurrency;
        require((_feeFrontend + _feeLP) < decimals.feeFractionsDecimals, "SET1"); //Error on setup: fee fractions do not sum to 1
        feeFrontend = _feeFrontend;
        feeLP = _feeLP;
        require(_tradingFee >= 0 && _tradingFee < decimals.tradingFeeDecimals, "SET5");
        tradingFee = _tradingFee;
        require(_flatTradingFee*1e18 < (decimals.tradingFeeDecimals - _tradingFee)*minimumTradeSize, "SET6");
        flatTradingFee = _flatTradingFee;
        require(_feeProtocolAddr != address(0), "SET7");
        feeProtocolAddr = _feeProtocolAddr;
        emaParam = _emaParam;
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(MOD_ROLE, _msgSender());
        liquidityM = [
        [int256(1) * decimals.liquidityMDecimals, int256(0) * decimals.liquidityMDecimals],
        [int256(0) * decimals.liquidityMDecimals, int256(1) * decimals.liquidityMDecimals]
        ];
    }
}