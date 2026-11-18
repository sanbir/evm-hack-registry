// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./66161-c-07-users-can-accumulate-rewards-after-lock-expiry-due-to-s.sol";

contract Finding66161Test is Test {

    function test_exploit_expired_lock_still_paid() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.live(), 0, "expired");
        assertEq(e.paid(), 1000 ether, "stale");
        assertEq(e.token().balanceOf(address(this)), 1000 ether, "drained");
        assertEq(e.token().balanceOf(address(e.ve())), 0, "empty");
    }

    function test_control_current_power_pays_zero() public {
        Exploit e = new Exploit();
        e.ve().lock(address(this), 1000 ether);
        e.ve().notify(1e18);
        assertEq(e.ve().balanceOf(address(this)), 0, "live power");
        assertEq(e.ve().currentRewards(address(this)), 0, "fixed formula");
        assertEq(e.ve().getNewUserRewards(address(this), address(e.token())), 1000 ether, "buggy formula");
    }

}
