// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./54897-baddebtmappingcollateral-can-be-unintentionally-rewrite-cant.sol";

contract Finding54897Test is Test {
    function test_overwrite_lets_10_of_debt_sweep_910_collateral() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.swept(), 910 ether, "swept");
        assertEq(e.collateral().balanceOf(address(e)), 910 ether, "attacker");
        assertEq(e.collateral().balanceOf(address(e.vault())), 0, "vault");
        assertEq(e.vault().badDebtMapping(address(e.collateral())), 0, "cleared");
    }

    function test_control_plus_equals_pays_only_the_second_slice() public {
        uint256 recorded = 900 ether + 10 ether;
        uint256 fair = (uint256(10 ether) * uint256(910 ether)) / recorded;
        assertEq(fair, 10 ether, "fair collateral");
    }
}
