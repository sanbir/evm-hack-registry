// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20, Pool, Oracle, Lender} from
    "./45983-c-01-using-spot-price-can-cause-a-price-manipulation-attack.sol";

contract Finding45983Test is Test {
    function test_exploit_spot_skew_borrows_32_against_10() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token1().balanceOf(address(e)), 32 ether, "borrowed");
        assertEq(e.token1().balanceOf(address(e.lender())), 0, "lender");
        assertEq(e.oracle().lastSqrt(), uint160(e.Q96() * 2), "spot");
        assertEq(e.pool().twap(), uint160(e.Q96()), "twap");
    }

    function test_control_twap_lends_eight() public {
        ERC20 token0 = new ERC20("TKN");
        ERC20 token1 = new ERC20("DAI");
        uint256 q96 = uint256(1) << 96;
        Pool pool = new Pool(uint160(q96));
        Oracle oracle = new Oracle(true);
        Lender lender = new Lender(token0, token1, oracle, pool);
        token0.mint(address(this), 10 ether);
        token1.mint(address(lender), 32 ether);
        pool.skew(uint160(q96 * 2));
        token0.approve(address(lender), 10 ether);
        uint256 got = lender.borrow(10 ether);
        assertEq(got, 8 ether, "fair 80% of 10");
        assertEq(oracle.lastSqrt(), uint160(q96), "twap used");
        assertEq(token1.balanceOf(address(lender)), 24 ether, "lender keeps the rest");
    }
}
