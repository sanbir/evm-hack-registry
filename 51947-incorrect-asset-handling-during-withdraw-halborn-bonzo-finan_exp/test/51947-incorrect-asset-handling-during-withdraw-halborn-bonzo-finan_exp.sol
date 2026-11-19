// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, ERC20Mini, LendingPoolFixed} from "./51947-incorrect-asset-handling-during-withdraw-halborn-bonzo-finan.sol";

contract WhbarWithdrawTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_withdrawToOtherAddressPaysTwice() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.whbar().balanceOf(SINK), 100 ether, "recipient got the burned WHBAR");
        assertEq(exp.hbar().balanceOf(SINK), 100 ether, "recipient also got unwrapped HBAR");
        assertEq(exp.whbar().balanceOf(address(exp)), 0, "caller paid a second 100 ether");
        assertEq(exp.pool().extraPaid(), 100 ether, "extra leg is 100 ether");
        assertEq(exp.pool().aBalance(address(exp)), 0, "aToken balance was burned");
    }

    function test_control_unwrapsOnceAndLeavesWalletWhbar() public {
        ERC20Mini whbar = new ERC20Mini("WHBAR");
        ERC20Mini hbar = new ERC20Mini("HBAR");
        LendingPoolFixed pool = new LendingPoolFixed(whbar, hbar);
        whbar.mint(address(pool), 100 ether);
        hbar.mint(address(pool), 100 ether);
        whbar.mint(address(this), 100 ether);
        pool.bootstrap(address(this), 100 ether);

        pool.withdraw(100 ether, SINK);

        assertEq(whbar.balanceOf(SINK), 0, "control does not send the extra 100 WHBAR");
        assertEq(hbar.balanceOf(SINK), 100 ether, "recipient gets one unwrap");
        assertEq(whbar.balanceOf(address(this)), 100 ether, "caller wallet is untouched");
    }
}
