// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./28529-reward-sniffing-mixbytes-none-nucypher-markdown.sol";

contract Finding28529Test is Test {
    function test_hundred_deposit_withdraws_sniff_800() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.sniffed(), 800, "sniffed");
        assertEq(e.poolFree(), 99200, "pool");
        assertEq(e.user1Owed(), 108199, "owed");
        console2.log("sniffed", e.sniffed());
        console2.log("pool free", e.poolFree());
        console2.log("user1 owed", e.user1Owed());
    }

    function test_control_unstaked_pool_pays_zero_reward() public {
        Exploit e = new Exploit();
        e.runUnstaked();
        assertEq(e.sniffed(), 0, "no sniff");
        assertEq(e.poolFree(), 100_000, "intact");
        console2.log("control sniffed", e.sniffed());
        console2.log("control pool free", e.poolFree());
    }
}
