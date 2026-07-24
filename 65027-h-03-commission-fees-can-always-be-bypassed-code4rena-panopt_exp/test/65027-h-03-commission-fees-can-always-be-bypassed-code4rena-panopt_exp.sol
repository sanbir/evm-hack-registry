// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65027-h-03-commission-fees-can-always-be-bypassed-code4rena-panopt.sol";

contract CommissionBypassTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.commissionAfterBypass(), 0, "bypass: zero commission");
        assertGt(e.commissionHonestWouldPay(), 0, "honest path would pay");
    }

    function test_honest_burn_pays_commission() public {
        CollateralTracker ct = new CollateralTracker();
        PanopticPool pool = new PanopticPool(ct, 1000, 100);
        ct.setPool(address(pool));
        address user = address(0xC);
        ct.seed(user, 10_000_000);
        pool.openPosition(user, 1_000_000, 50_000);
        pool.burnWithPremium(user);
        assertEq(ct.totalCommissionPaid(), 5000, "min(premiumFee,notionalFee)=5000");
    }
}
