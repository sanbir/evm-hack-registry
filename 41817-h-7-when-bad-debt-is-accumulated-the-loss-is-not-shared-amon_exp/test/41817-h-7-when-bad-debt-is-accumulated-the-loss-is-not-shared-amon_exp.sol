// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, TokenB, PoolFixed} from "./41817-h-7-when-bad-debt-is-accumulated-the-loss-is-not-shared-amon.sol";

contract Finding41817Test is Test {
    address internal constant SUPPLIER = 0x000000000000000000000000000000000000B0b2;

    function test_exploit_early_withdrawer_takes_the_unsocialized_share() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.earlyOut(), 50 ether, "early supplier got 50");
        assertEq(e.cashAfterEarly(), 14 ether, "14 left after the race");
        assertTrue(e.lateFullReverted(), "late full withdraw reverts");
        assertEq(e.lateOut(), 14 ether, "late supplier got 14");
        assertEq(e.token().balanceOf(address(e)), 50 ether, "early balance");
        assertEq(e.token().balanceOf(SUPPLIER), 14 ether, "late balance");
    }

    function test_control_socialized_index_splits_the_remaining_cash() public {
        TokenB token = new TokenB();
        PoolFixed fixedPool = new PoolFixed(token);
        token.mint(address(fixedPool), 64 ether);
        uint256 index = 64 ether * 1e27 / 100 ether;
        fixedPool.setIndex(address(token), index);
        fixedPool.setSupply(address(token), address(this), 50 ether);
        fixedPool.setSupply(address(token), SUPPLIER, 50 ether);

        uint256 early = fixedPool.withdrawSimple(address(token), address(this), 32 ether);
        uint256 late = fixedPool.withdrawSimple(address(token), SUPPLIER, 32 ether);

        assertEq(early, 32 ether, "early fair share");
        assertEq(late, 32 ether, "late fair share");
        assertEq(token.balanceOf(address(fixedPool)), 0, "pool empty");
        assertEq(token.balanceOf(SUPPLIER), 32 ether, "supplier recovered 32");
    }
}
