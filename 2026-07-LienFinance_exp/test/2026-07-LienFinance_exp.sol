// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, BondMaker, GeneralizedDotc, MiniUSDC} from "./2026-07-LienFinance.sol";

contract LienFinanceTest is Test {
    function test_exploit_craftedBondPayoff_drainsLpUsdc() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_decimal_uint("USDC drained from LP", e.usdcOut(), 6);
        emit log_named_decimal_uint("attacker USDC profit", e.profit(), 6);
        assertGe(e.profit(), 542_000_000_000, "must drain the LP USDC");
    }
}
