// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./42042-missing-call-to-computecollateralorlvlusdamount-in-levelmint.sol";

contract Finding42042Test is Test {
    function test_exploit_mints_unbacked_lvlusd_and_redeems_reserve() public {
        Exploit e = new Exploit();
        uint256 beforeBal = e.collateral().balanceOf(address(e));
        e.run();
        assertEq(beforeBal, 1, "started with 1 wei");
        assertEq(e.attackerCollateral(), 100 ether, "took the reserve");
        assertEq(e.collateral().balanceOf(address(e)) - beforeBal, 100 ether - 1, "profit");
        assertEq(e.reserveLeft(), 0, "reserve empty");
    }

    function test_control_recomputes_collateral() public {
        Exploit e = new Exploit();
        e.runFixed();
        assertEq(e.collateral().balanceOf(address(e)), 1, "attacker still has 1 wei");
        assertEq(e.collateral().balanceOf(address(e.minting())), 100 ether, "reserve intact");
    }
}
