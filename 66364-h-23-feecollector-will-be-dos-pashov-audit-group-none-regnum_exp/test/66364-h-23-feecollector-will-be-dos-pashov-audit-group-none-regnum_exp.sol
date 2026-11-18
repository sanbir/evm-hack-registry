// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Token, HonestPool, FakePool, FeeCollectorFixed} from
    "./66364-h-23-feecollector-will-be-dos-pashov-audit-group-none-regnum.sol";

contract Finding66364Test is Test {
    function test_exploit_inflated_fees_lock_100_raac() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stuck(), 100 ether, "real fees stuck");
        assertEq(e.treasuryBook(), 500 ether, "book is 500");
        assertTrue(e.distributeReverted(), "distribute reverted");
        assertEq(e.token().balanceOf(address(e.collector())), 100 ether, "collector holds 100");
    }

    function test_control_balance_check_lets_real_fees_distribute() public {
        Token token = new Token();
        HonestPool honest = new HonestPool();
        FakePool fake = new FakePool();
        FeeCollectorFixed fixedCollector = new FeeCollectorFixed(token, address(honest));
        token.mint(address(honest), 100 ether);

        vm.expectRevert(bytes("short"));
        fixedCollector.claimNFTUnderlying(address(token), address(fake), 1000 ether);

        fixedCollector.claimNFTUnderlying(address(token), address(honest), 100 ether);
        fixedCollector.distribute(address(this));

        assertEq(token.balanceOf(address(fixedCollector)), 0, "collector empty");
        assertEq(token.balanceOf(address(this)), 100 ether, "treasury received 100");
        assertEq(fixedCollector.accounted(), 0, "books cleared");
    }
}
