// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./58385-h-16-coreroutersols-repayborrowinternal-incorrectly-updates.sol";

contract Finding58385Test is Test {
    function test_exploit_cross_chain_repay_erases_same_chain_debt() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(this)), 1000 ether, "borrower kept 1000");
        assertEq(e.sameDebt(), 0, "same-chain debt erased");
        assertEq(e.crossDebt(), 0, "cross-chain debt repaid");
        assertEq(e.token().balanceOf(address(e.router())), 1000 ether, "pool is short the erased loan");
    }

    function test_control_fixed_repay_keeps_same_chain_debt() public {
        Exploit e = new Exploit();
        e.runFixed();
        assertEq(e.router().sameChainDebt(address(e)), 1000 ether, "same-chain debt remains");
        assertEq(e.router().crossChainDebt(address(e)), 0, "cross-chain debt cleared");
    }
}
