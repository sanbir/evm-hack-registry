// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./44338-s-votesbypoolm-pool-persists-indefinitely-leading-to-rewards.sol";

contract Finding44338Test is Test {
    function test_expired_lock_still_directs_1000() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.reward().balanceOf(address(e.gauge())), 1000, "gauge");
        assertEq(e.mgr().fairWeight(1), 0, "live");
        assertEq(e.mgr().s_votesByPool(address(e.gauge())), 1000, "stored");
        console2.log("gauge reward", e.reward().balanceOf(address(e.gauge())));
        console2.log("live weight", e.mgr().fairWeight(1));
    }
}
