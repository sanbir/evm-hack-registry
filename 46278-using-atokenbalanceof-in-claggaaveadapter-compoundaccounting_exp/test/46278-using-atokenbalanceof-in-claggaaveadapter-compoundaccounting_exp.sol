// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit} from "./46278-using-atokenbalanceof-in-claggaaveadapter-compoundaccounting.sol";
contract Finding46278Test is Test {
    function test_exploit_victim_deposit_mints_zero_shares() public {
        Exploit e = new Exploit();
        uint256 beforeBal = e.token().balanceOf(address(e.attacker()));
        e.run();
        assertEq(e.vault().sharesOf(address(e.victim())), 0);
        assertEq(e.token().balanceOf(address(e.victim())), 0);
        assertEq(e.token().balanceOf(address(e.attacker())) - beforeBal, 10 ether);
    }
}
