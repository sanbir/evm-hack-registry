// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, TeaVaultAmbient} from "./45706-management-fee-for-the-first-time-will-be-way-larger-than-it.sol";

contract Finding45706Test is Test {
    function test_first_fee_exceeds_the_deposit() public {
        vm.warp(1784893842);
        Exploit e = new Exploit();
        e.run();
        assertEq(e.fair(), 0, "fair");
        assertGt(e.feeMinted(), 1000 ether, "fee larger than deposit");
        emit log_named_uint("feeMinted", e.feeMinted());
        assertEq(e.vault().balanceOf(address(0x1111111111111111111111111111111111111111)), e.feeMinted(), "manager");
    }

    function test_control_initialized_clock_charges_zero() public {
        vm.warp(1784893842);
        TeaVaultAmbient v = new TeaVaultAmbient(true);
        v.deposit();
        assertEq(v.collect(), 0, "no fee in the open block");
    }
}
