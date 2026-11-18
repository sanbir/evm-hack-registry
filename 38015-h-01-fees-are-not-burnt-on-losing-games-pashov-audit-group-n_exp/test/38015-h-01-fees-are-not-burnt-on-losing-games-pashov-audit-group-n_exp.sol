// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, MockToken, Burner, Vault} from
    "./38015-h-01-fees-are-not-burnt-on-losing-games-pashov-audit-group-n.sol";

contract Finding38015Test is Test {
    function test_exploit_losing_bet_pays_burner_zero_and_mints_mont() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.vault().pendingBurn(), 80e6, "80 USDT was owed");
        assertEq(e.usdt().balanceOf(address(e.burner())), 0, "burner received 0");
        assertEq(e.mont().balanceOf(address(e)), 100 ether, "100 MONT still paid");
        assertEq(e.usdt().balanceOf(address(e.vault())), 1000e6, "fee stayed in the vault");
        assertFalse(e.vault().winnerBranchTaken(), "winner branch not taken");
    }

    function test_control_winning_bet_sends_80_usdt_to_the_burner() public {
        MockToken usdt = new MockToken();
        MockToken mont = new MockToken();
        Burner burner = new Burner();
        Vault vault = new Vault(usdt, mont, burner);
        usdt.mint(address(vault), 1000e6);

        vault.transferPlayerRewards(true, 100e6, address(this));

        assertEq(usdt.balanceOf(address(burner)), 80e6, "winner path funds the burner");
        assertTrue(vault.winnerBranchTaken(), "winner branch taken");
    }
}
