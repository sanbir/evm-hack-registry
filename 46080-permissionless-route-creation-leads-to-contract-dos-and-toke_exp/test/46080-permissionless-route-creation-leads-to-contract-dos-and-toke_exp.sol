// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20, Admin, ForwarderHashedTimelockERC20} from "./46080-permissionless-route-creation-leads-to-contract-dos-and-toke.sol";

contract Finding46080Test is Test {
    function test_exploit_attacker_steals_100_and_blocks_admin() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.adminBlocked());
        assertEq(e.token().balanceOf(address(e)), 100 ether);
        assertEq(e.token().balanceOf(address(e.forwarder())), 0);
        assertEq(e.forwarder().timelock(), type(uint256).max);
    }

    function test_control_owner_only_route_keeps_admin_sweep() public {
        ERC20 token = new ERC20();
        Admin admin = new Admin();
        ForwarderHashedTimelockERC20 f = new ForwarderHashedTimelockERC20(address(admin));
        token.mint(address(f), 100 ether);
        // No route was created, so the admin can still sweep.
        admin.sweep(f, address(token), address(this), 100 ether);
        assertEq(token.balanceOf(address(this)), 100 ether);
        assertEq(token.balanceOf(address(f)), 0);
    }
}
