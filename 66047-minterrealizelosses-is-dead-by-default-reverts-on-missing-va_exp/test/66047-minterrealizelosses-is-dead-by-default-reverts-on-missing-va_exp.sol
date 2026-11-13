// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Base, Hil, VaultWithBurn} from
    "./66047-minterrealizelosses-is-dead-by-default-reverts-on-missing-va.sol";

contract Finding66047Test is Test {
    function test_exploit_missing_allowance_overpays_the_redeemer_by_20() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.lossesReverted(), "realizeLosses reverted");
        assertEq(e.hil().balanceOf(address(e.vault())), 300 * 1e8, "hil not burned");
        assertEq(e.hil().allowance(address(e.vault()), address(e.minter())), 0, "allowance still 0");
        assertEq(e.paid(), 200 * 1e8, "paid 200");
        assertEq(e.base().balanceOf(address(e)), 200 * 1e8, "redeemer received 200");
        assertEq(e.base().balanceOf(address(e.vault())), 70 * 1e8, "other depositor left with 70, not 90");
    }

    function test_control_vault_burns_its_own_balance_and_redeem_pays_180() public {
        Base base = new Base();
        Hil hil = new Hil(address(this));
        VaultWithBurn vault = new VaultWithBurn(hil, base);
        hil.mint(address(vault), 300 * 1e8);
        base.mint(address(vault), 270 * 1e8);
        vault.setShares(address(this), 200 * 1e8);
        vault.setShares(address(0xBEEF), 100 * 1e8);
        vault.setMinter(address(this));
        vault.burnOwn(30 * 1e8);

        uint256 paid = vault.redeem(200 * 1e8);
        assertEq(hil.balanceOf(address(vault)), 270 * 1e8, "loss was burned before the redeem");
        assertEq(paid, 180 * 1e8, "fair 180");
        assertEq(base.balanceOf(address(vault)), 90 * 1e8, "other depositor keeps 90");
        assertEq(base.balanceOf(address(this)), 180 * 1e8, "redeemer received fair share");
    }
}
