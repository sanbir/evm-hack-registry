// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit, TradingStorageFixed, MockToken, GToken} from "./37793-h-04-collateral-not-approved-after-updating-of-gtoken-addres.sol";
contract Finding37793Test is Test {
    function test_new_gtoken_cannot_pull() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.pullReverted());
        assertEq(e.stuck(), 1000e6);
        assertEq(e.allowanceLeft(), 0);
        assertEq(e.token().balanceOf(address(e.freshG())), 0);
    }
    function test_control_update_approves_and_pulls() public {
        MockToken token = new MockToken();
        GToken oldG = new GToken(token);
        GToken fresh = new GToken(token);
        TradingStorageFixed store = new TradingStorageFixed(token);
        token.mint(address(store), 1000e6);
        store.addCollateral(address(token), address(oldG));
        store.updateGToken(address(token), address(fresh));
        fresh.pull(address(store), 1000e6);
        assertEq(token.balanceOf(address(fresh)), 1000e6);
        assertEq(token.balanceOf(address(store)), 0);
    }
}
