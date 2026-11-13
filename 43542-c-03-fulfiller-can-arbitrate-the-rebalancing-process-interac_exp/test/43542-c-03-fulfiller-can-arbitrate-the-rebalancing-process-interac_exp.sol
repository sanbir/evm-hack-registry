// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Erc20, Desk, BunniPoolFixed} from
    "./43542-c-03-fulfiller-can-arbitrate-the-rebalancing-process-interac.sol";

contract Finding43542Test is Test {
    function test_exploit_deposit_during_rebalance_extracts_150() public {
        Exploit e = new Exploit();
        uint256 before0 = e.t0().balanceOf(address(e));
        e.run();
        assertEq(e.end0(), before0 + 225 ether, "token0");
        assertEq(e.end1(), 225 ether, "token1");
        assertEq(e.end0() + e.end1(), before0 + e.D() + 150 ether, "net");
    }

    function test_control_deposit_after_both_reserves_move_is_neutral() public {
        Erc20 t0 = new Erc20("T0");
        Erc20 t1 = new Erc20("T1");
        Desk desk = new Desk();
        BunniPoolFixed pool = new BunniPoolFixed(t0, t1);
        uint256 R = 1200 ether;
        uint256 K = 600 ether;
        uint256 D = 300 ether;
        t0.mint(address(this), R + D + K);
        t1.mint(address(this), R + D);
        t0.mint(address(desk), K);
        t0.approve(address(pool), type(uint256).max);
        t1.approve(address(pool), type(uint256).max);
        pool.seed(R);
        uint256 start0 = t0.balanceOf(address(this));
        uint256 start1 = t1.balanceOf(address(this));
        t1.approve(address(desk), K);
        pool.rebalance(address(this), K, K);
        // the 1:1 hedge of the tokenIn just received, then the deposit
        desk.take(t1, t0, K);
        pool.deposit(D, D);
        pool.withdraw();
        uint256 end0 = t0.balanceOf(address(this));
        uint256 end1 = t1.balanceOf(address(this));
        assertEq(end0 + end1, start0 + start1, "value neutral");
        assertEq(end0, start0 + 120 ether, "fair token0 shift");
    }
}
