// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Lst, Vault, CNumaGuarded, GuardedFake} from
    "./45276-h-1-cnumatokenleveragestrategy-can-be-re-entered-causing-all.sol";

contract Finding45276Test is Test {
    function test_exploit_reentered_leverage_sticks_10_lst_in_cnuma() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.lst().balanceOf(address(e.cNuma())), 10 ether, "10 LST stuck in cNuma");
        assertEq(e.lst().balanceOf(address(e.vault())), 1 ether, "vault price dropped by 10");
        assertEq(e.vault().leverageDebt(), 0, "debt cleared without the outer repay");
        assertEq(e.stuckInCNuma(), 10 ether, "recorded stuck");
        assertTrue(e.fake().entered(), "reentered");
    }

    function test_control_reentrancy_guard_keeps_the_vault_whole() public {
        Lst lst = new Lst();
        Vault vault = new Vault(lst);
        CNumaGuarded cNuma = new CNumaGuarded(vault, lst);
        vault.setCNuma(address(cNuma));
        GuardedFake fake = new GuardedFake(cNuma);
        lst.mint(address(vault), 11 ether);

        bool reverted;
        try cNuma.leverageStrategy(0, 10 ether, address(fake), 0) {
            reverted = false;
        } catch {
            reverted = true;
        }

        assertTrue(reverted, "reentry reverted");
        assertEq(lst.balanceOf(address(cNuma)), 0, "nothing stuck");
        assertEq(lst.balanceOf(address(vault)), 11 ether, "vault whole");
        assertEq(vault.leverageDebt(), 0, "debt rolled back");
    }
}
