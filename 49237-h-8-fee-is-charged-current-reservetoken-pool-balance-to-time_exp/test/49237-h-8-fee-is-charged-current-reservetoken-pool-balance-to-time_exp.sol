// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {Exploit} from "./49237-h-8-fee-is-charged-current-reservetoken-pool-balance-to-time.sol";
contract Finding49237Test is Test {
    function test_exploit_overcharges_fresh_deposit() public {
        vm.warp(1706591104);
        Exploit e = new Exploit();
        e.run();
        assertEq(e.taken(), 10.1 ether, "10.10 fee");
    }
    function test_control_claim_before_deposit_charges_0_10() public {
        vm.warp(1706591104);
        Exploit e = new Exploit();
        e.runAccruedFirst();
    }
}
