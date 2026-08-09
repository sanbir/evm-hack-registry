// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    CollateralManager,
    CollateralManagerFixed,
    MiniToken,
    MiniVault,
    IERC4626
} from "./64975-direct-vault-deposits-incorrectly-counted-as-revenue-leading.sol";

contract DirectVaultDepositAsRevenueTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant THIRD_PARTY = 0x000000000000000000000000000000000000bEEF;

    uint256 internal constant VAULT_PRINCIPAL = 1000 ether;
    uint256 internal constant MANAGER_RESERVE = 1000 ether;
    uint256 internal constant D = 1000 ether; // third-party direct deposit

    // ── the bug: a third-party direct deposit is drained as protocol "revenue" ──
    function test_exploit_directDepositDrainsPrincipal() public {
        Exploit e = new Exploit();

        MiniToken collateral = MiniToken(e.collateralAddr());
        address managerAddr = e.managerAddr();

        // manager starts with its direct principal reserve
        assertEq(collateral.balanceOf(managerAddr), MANAGER_RESERVE, "manager reserve pre-attack");

        e.run();

        // the manager's principal reserve was fully drained by the collector
        assertEq(e.managerReserveBefore(), MANAGER_RESERVE, "reserve before drain");
        assertEq(e.managerReserveAfter(), 0, "reserve fully drained");
        assertEq(e.drained(), D, "exactly the third-party deposit was drained");

        // yet the protocol earned ZERO real yield (manager-owned share value unchanged)
        assertEq(e.trueProtocolYield(), 0, "no real protocol yield");

        // the drained principal landed at the SINK (collector sink)
        assertEq(e.sinkBalance(), D, "sink received drained principal");
        assertEq(collateral.balanceOf(SINK), D, "sink holds drained collateral");

        // and the third party still owns the deposit it made (shares in the vault),
        // so the drained collateral truly came out of protocol principal, not yield.
        MiniVault vault = MiniVault(e.vaultAddr());
        assertEq(vault.balanceOf(THIRD_PARTY), D, "third party still owns its vault shares");
    }

    // ── negative control: the recommended fix computes 0 revenue, so the ──
    //    identical collector withdrawal reverts ExceedsPendingRevenue. ──
    function test_control_fixedRevenueValuesOwnSharesOnly() public {
        MiniToken collateral = new MiniToken("Tenbin Collateral", "LOST-COLL");
        MiniVault vault = new MiniVault(collateral);
        CollateralManagerFixed manager = new CollateralManagerFixed();

        // this test contract acts as the collector
        manager.setupGrantCollector(address(this));
        manager.setupRegisterVault(address(collateral), IERC4626(address(vault)));

        // fund + deposit principal, record baseline (protocol-owned share value)
        collateral.mint(address(manager), VAULT_PRINCIPAL + MANAGER_RESERVE);
        manager.setupDepositPrincipal(address(collateral), VAULT_PRINCIPAL);

        // identical third-party direct deposit
        collateral.mint(address(this), D);
        collateral.approve(address(vault), D);
        vault.deposit(D, THIRD_PARTY);

        // fixed accounting: protocol-owned shares still worth VAULT_PRINCIPAL,
        // so revenue == 0 and the collector's withdrawal is rejected.
        vm.expectRevert(CollateralManagerFixed.ExceedsPendingRevenue.selector);
        manager.withdrawRevenue(address(collateral), D);

        // principal is intact under the fix
        assertEq(collateral.balanceOf(address(manager)), MANAGER_RESERVE, "fixed: principal untouched");
    }
}
