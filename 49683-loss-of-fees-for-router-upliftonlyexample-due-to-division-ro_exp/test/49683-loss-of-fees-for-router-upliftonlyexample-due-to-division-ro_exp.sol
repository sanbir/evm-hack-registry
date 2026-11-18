// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20, Router, Hook} from
    "./49683-loss-of-fees-for-router-upliftonlyexample-due-to-division-ro.sol";

contract Finding49683Test is Test {
    function test_exploit_sixty_percent_take_pays_admin_everything() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.hook().adminFee(), 1000 ether, "admin fee");
        assertEq(e.hook().ownerFee(), 0, "owner fee");
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "admin balance");
        assertEq(e.token().balanceOf(address(e.router())), 0, "router");
    }

    function test_control_multiply_first_splits_60_40() public {
        ERC20 token = new ERC20();
        Router router = new Router();
        Hook hook = new Hook(token, address(this), address(router), 0.6 ether, true);
        token.mint(address(hook), 1000 ether);
        hook.onAfterSwap();
        assertEq(hook.adminFee(), 600 ether, "admin 60%");
        assertEq(hook.ownerFee(), 400 ether, "router 40%");
        assertEq(token.balanceOf(address(this)), 600 ether, "admin");
        assertEq(token.balanceOf(address(router)), 400 ether, "router");
    }
}
