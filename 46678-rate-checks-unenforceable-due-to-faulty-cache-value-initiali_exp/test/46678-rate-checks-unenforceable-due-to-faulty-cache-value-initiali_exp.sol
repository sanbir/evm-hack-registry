// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, VaultOrderbook} from "./46678-rate-checks-unenforceable-due-to-faulty-cache-value-initiali.sol";

contract Finding46678Test is Test {
    function test_exploit_seeded_cache_takes_lp_deposit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.base().balanceOf(address(this)), 1000 ether, "attacker received the LP deposit");
        assertEq(e.realReward().balanceOf(address(e.lp())), 0, "LP got no reward");
        assertEq(e.base().balanceOf(address(e.lp())), 0, "LP lost the base");
        assertEq(e.profit(), 1000 ether, "profit");
    }

    function test_control_zero_cache_reverts() public {
        Exploit e = new Exploit();
        vm.expectRevert(VaultOrderbook.OrderConditionsNotMet.selector);
        e.runFixed();
    }
}
