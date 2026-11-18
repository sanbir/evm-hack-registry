// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Token, Dex, LeverageManagerFixed} from
    "./52751-h-6-leveragemanager-remove-leverage-will-lead-to-stuck-token.sol";

contract Finding52751Test is Test {
    function test_exploit_75_borrow_tokens_stuck() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stuck(), 75 ether, "75 stuck in the manager");
        assertEq(e.userBorrow(), 0, "user received none");
        assertEq(e.borrowToken().balanceOf(e.FLASH()), 120 ether, "flash repaid");
        assertEq(e.borrowToken().balanceOf(address(e.manager())), 75 ether, "manager balance");
    }

    function test_control_returns_the_slippage_surplus() public {
        Token pod = new Token("pTKN");
        Token borrowToken = new Token("BORROW");
        Dex dex = new Dex(borrowToken);
        pod.setDex(address(dex));
        address flash = address(0xF1A5);
        LeverageManagerFixed fixedMgr = new LeverageManagerFixed(pod, borrowToken, dex, flash);
        pod.mint(address(this), 100 ether);
        borrowToken.mint(address(this), 100 ether);
        borrowToken.mint(address(dex), 95 ether);
        pod.approve(address(fixedMgr), 100 ether);
        borrowToken.approve(address(fixedMgr), 100 ether);

        uint256 returned = fixedMgr.removeLeverage(100 ether, 100 ether, 120 ether, 95 ether);

        assertEq(returned, 75 ether, "returned 75");
        assertEq(borrowToken.balanceOf(address(this)), 75 ether, "user holds 75");
        assertEq(borrowToken.balanceOf(address(fixedMgr)), 0, "manager empty");
        assertEq(borrowToken.balanceOf(flash), 120 ether, "flash repaid");
    }
}
