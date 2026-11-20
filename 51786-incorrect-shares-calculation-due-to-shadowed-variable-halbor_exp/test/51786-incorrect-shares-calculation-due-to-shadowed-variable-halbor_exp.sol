// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, VaultFixed} from "./51786-incorrect-shares-calculation-due-to-shadowed-variable-halbor.sol";

contract Finding51786Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_decay_loop_does_not_run() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vault().lastMinted(), 10000 ether, "full stake minted");
        assertEq(e.vault().outerDays(), 0, "outer days are 0");
        assertEq(e.marker().balanceOf(SINK), 70 ether, "70 extra");
    }

    function test_control_two_days_mint_9930() public {
        assertEq(new VaultFixed().preview(2, 10000 ether), 9930 ether, "two decays");
    }
}
