// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./61229-dust-limit-attack-on-forceupdatenodes-allows-dos-of-rebalanc.sol";
contract Finding61229Test is Test {
    function test_exploit_dust_blocks_rebalance() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stayed(), 600e18, "600 stayed");
        assertTrue(e.vulnBlocked(), "blocked");
        assertEq(e.controlMoved(), 600e18, "control moved 600");
    }
}
