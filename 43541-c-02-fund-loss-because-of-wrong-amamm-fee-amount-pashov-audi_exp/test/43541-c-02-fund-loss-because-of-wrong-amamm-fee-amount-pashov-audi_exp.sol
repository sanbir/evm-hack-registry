// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit} from "./43541-c-02-fund-loss-because-of-wrong-amamm-fee-amount-pashov-audi.sol";
contract Finding43541Test is Test {
    function test_amamm_takes_hook_fee_and_referrer_is_paid_again() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.managerGot(), 100e18);
        assertEq(e.referrerGot(), 10e18);
        assertEq(e.hookLeft(), 0);
        assertGt(e.managerGot(), 80e18);
    }
}
