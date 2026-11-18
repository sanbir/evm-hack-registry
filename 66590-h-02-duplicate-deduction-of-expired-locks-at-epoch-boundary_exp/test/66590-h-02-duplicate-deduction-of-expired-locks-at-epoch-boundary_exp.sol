// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, LockManager} from "./66590-h-02-duplicate-deduction-of-expired-locks-at-epoch-boundary.sol";

contract Finding66590Test is Test {
    function test_exploit_vote_stays_158() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.buggyBias(), 158, "bias stays 158");
        assertEq(e.fairBias(), 133, "fair bias is 133");
        assertEq(e.buggyBase(), 0, "base zeroed");
        assertEq(e.fairBase(), 100, "fair base is 100");
    }

    function test_control_skip_zero_duration_decays_to_133() public {
        LockManager locks = new LockManager();
        address voter = address(0xB0B);
        locks.setExpired(voter, locks.WEEK(), 100);
        (int128 bias, uint256 base) = locks.fairDecay(voter, 158, 100, locks.WEEK(), locks.WEEK() * 2);
        assertEq(bias, 133, "decays");
        assertEq(base, 100, "lock remains");
        assertLt(bias, 140, "does not beat 140");
    }
}
