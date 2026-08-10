// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    Vault,
    VaultFixed,
    MiniToken,
    IERC20
} from "./62716-h-01-full-restricted-users-can-still-deposit-kann-none-manif.sol";

// ManifestFinance H-01 (Kann Audits): FULL_RESTRICTED users can still deposit.
// The vault's compliance gate lives only in the ERC20 `_update` override, which
// checks `from`/`to`. The `_mint` path calls `_update(address(0), receiver, ...)`
// and never checks the CALLER, so a blacklisted (FULL_RESTRICTED) user can
// deposit by naming a clean receiver.
contract FullRestrictedCanStillDepositTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant CLEAN_RECEIVER = 0x0000000000000000000000000000000000002222;

    function test_exploit_fullRestrictedCallerBypassesDepositRestriction() public {
        Exploit e = new Exploit();
        e.run();

        // The blacklisted caller's deposit — which MUST revert — instead succeeded.
        assertTrue(e.buggyDepositSucceeded(), "restricted deposit should have succeeded via the bug");

        // 1000e18 shares were minted to the clean receiver the attacker controls.
        assertEq(e.mintedShares(), 1000 ether, "shares minted count");
        Vault vault = Vault(e.vaultAddr());
        assertEq(vault.balanceOf(CLEAN_RECEIVER), 1000 ether, "clean receiver holds bypassed shares");

        // The caller genuinely held FULL_RESTRICTED — this was a real compliance bypass.
        assertTrue(
            vault.hasRole(vault.FULL_RESTRICTED_STAKER_ROLE(), address(e)),
            "caller must hold FULL_RESTRICTED_STAKER_ROLE"
        );

        // Harm magnitude recorded on the marker at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 1000 ether, "marker records bypassed-share magnitude at SINK");

        // NEGATIVE CONTROL: the fixed vault blocked the identical restricted caller.
        assertTrue(e.fixedDepositReverted(), "fixed vault must revert for a FULL_RESTRICTED caller");
    }

    // Direct negative control against the fixed variant: a blacklisted caller's
    // deposit reverts with OperationNotAllowed.
    function test_control_fixedVault_blocksRestrictedCaller() public {
        MiniToken asset = new MiniToken("Manifest Asset", "mUSD");
        VaultFixed fixedVault = new VaultFixed(IERC20(address(asset)), "Staked Manifest Fixed", "sFIX");

        // This test contract is the FULL_RESTRICTED caller.
        fixedVault.grantRoleForTest(fixedVault.FULL_RESTRICTED_STAKER_ROLE(), address(this));
        asset.mint(address(this), 1000 ether);
        asset.approve(address(fixedVault), type(uint256).max);

        vm.expectRevert(VaultFixed.OperationNotAllowed.selector);
        fixedVault.deposit(1000 ether, CLEAN_RECEIVER);
    }
}
