// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    StylusPool,
    SeawaterAMMFixed
} from "./45235-h-01-createpoold650e2d0-will-not-work-due-to-mismatch-in-sol.sol";

contract Finding45235Test is Test {
    function test_exploit_create_reverts_and_liquidity_stays() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.createReverted(), "create reverted");
        assertTrue(e.depositReverted(), "deposit reverted");
        assertFalse(e.stylus().created(), "pool must not exist");
        assertEq(e.stylus().liquidity(), 0, "no liquidity recorded");
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "caller still holds 1000");
        emit log_named_uint("caller_liquidity_stuck", e.token().balanceOf(address(e)));
        emit log_named_uint("pool_liquidity", e.stylus().liquidity());
    }

    function test_control_matching_signature_creates_pool() public {
        MockToken token = new MockToken();
        StylusPool stylus = new StylusPool();
        SeawaterAMMFixed amm = new SeawaterAMMFixed(stylus, token);

        amm.createPoolMatching(address(token), uint256(1 << 96), 3000);
        assertTrue(stylus.created(), "pool created");
        assertEq(stylus.pool(), address(token), "pool token");
        assertEq(stylus.price(), uint256(1 << 96), "price");
        assertEq(stylus.fee(), 3000, "fee");

        token.mint(address(this), 1000 ether);
        token.approve(address(amm), 1000 ether);
        amm.deposit(1000 ether);

        assertEq(stylus.liquidity(), 1000 ether, "1000 deposited");
        assertEq(token.balanceOf(address(amm)), 1000 ether, "amm holds 1000");
        assertEq(token.balanceOf(address(this)), 0, "caller deposited all");
        emit log_named_uint("control_pool_liquidity", stylus.liquidity());
    }
}
