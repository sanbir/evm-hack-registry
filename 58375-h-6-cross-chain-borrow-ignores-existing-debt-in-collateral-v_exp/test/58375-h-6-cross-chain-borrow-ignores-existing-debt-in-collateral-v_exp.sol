// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./58375-h-6-cross-chain-borrow-ignores-existing-debt-in-collateral-v.sol";
contract Finding58375Test is Test {
    function test_cross_chain_borrow_exceeds_capacity() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.borrowed(), 700e18);
        assertEq(e.router().sentCollateral(), 800e18);
        assertGt(e.store().borrowed() + e.borrowed(), e.router().sentCollateral());
        assertEq(e.usdt().balanceOf(address(e.core())), 0);
    }
}
