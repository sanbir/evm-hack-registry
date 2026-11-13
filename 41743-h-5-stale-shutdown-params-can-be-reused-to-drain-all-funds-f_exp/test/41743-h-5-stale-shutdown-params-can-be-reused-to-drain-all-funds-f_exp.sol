// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./41743-h-5-stale-shutdown-params-can-be-reused-to-drain-all-funds-f.sol";

contract Finding41743Test is Test {
    function test_exploit_reuses_shutdown_params_to_take_1100_eth() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.eth().balanceOf(address(e)), 1100 ether, "stolen");
        assertEq(e.eth().balanceOf(address(e.shutdown())), 0, "drained");
    }

    function test_control_clearing_the_old_claim_keeps_the_eth() public {
        Exploit e = new Exploit();
        e.runFixed();
        assertEq(e.eth().balanceOf(address(e.shutdown())), 1100 ether, "kept");
        assertEq(e.eth().balanceOf(address(e)), 0, "none");
    }
}
