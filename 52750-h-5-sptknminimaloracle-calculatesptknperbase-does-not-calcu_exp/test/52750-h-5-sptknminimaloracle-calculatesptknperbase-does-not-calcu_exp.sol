// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, BaseToken, Pair, FraxlendPair, SpOracleFixed} from
    "./52750-h-5-sptknminimaloracle-calculatesptknperbase-does-not-calcu.sol";

contract Finding52750Test is Test {
    function test_exploit_fraxlend_ratio_after_invert_borrows_150() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.price(), 2 ether, "buggy price");
        assertEq(e.borrowed(), 150 ether, "borrow");
        assertEq(e.base().balanceOf(address(e)), 150 ether, "attacker");
        assertGt(e.borrowed(), e.fairMax(), "above the 37.5 fair max");
    }

    function test_control_cbr_before_invert_prices_at_half() public {
        Pair pair = new Pair();
        FraxlendPair frax = new FraxlendPair();
        SpOracleFixed oracle = new SpOracleFixed(pair, frax);
        uint256 price = oracle._calculateSpTknPerBase(1 ether);
        uint256 value = 100 ether * price / 1 ether;
        uint256 maxBorrow = value * 75 / 100;

        assertEq(price, 0.5 ether, "sp per base");
        assertEq(maxBorrow, 37.5 ether, "fair max");
    }
}
