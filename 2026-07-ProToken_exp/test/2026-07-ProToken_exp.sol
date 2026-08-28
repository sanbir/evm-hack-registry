// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, ProToken, Pair, MiniUSDT} from "./2026-07-ProToken.sol";

contract ProTokenTest is Test {
    function test_exploit_transferHookRewardSwap_drainsPair() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_decimal_uint("USDT drained from pair", e.drained(), 18);
        emit log_named_decimal_uint("attacker USDT profit", e.profit(), 18);
        assertGe(e.profit(), 600000e18, "must drain ~605K USDT");
    }
}
