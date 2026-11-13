// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    LPStakingFixed,
    LPToken,
    Reenterer,
    Victim
} from "./56308-reentrancy-attack-in-emergencywithdraw-function-zokyo-none-s.sol";

contract Finding56308Test is Test {
    function test_exploit_reenters_emergency_withdraw() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), 100 ether, "stole 100 LP");
        assertEq(e.received(), 200 ether, "paid twice");
        assertEq(e.rounds(), 1, "one reentry");
        assertEq(e.lp().balanceOf(address(e.staking())), 900 ether, "pool short 100");
    }

    function test_control_zero_before_transfer_pays_once() public {
        LPToken lp = new LPToken();
        LPStakingFixed staking = new LPStakingFixed(lp);
        Victim victim = new Victim();
        Reenterer attacker = new Reenterer();

        lp.mint(address(victim), 1_000 ether);
        victim.fundFixed(staking, lp, 1_000 ether);
        lp.mint(address(attacker), 100 ether);
        attacker.poke(staking, lp, 100 ether);

        assertEq(lp.balanceOf(address(attacker)), 100 ether, "only own stake");
        assertEq(lp.balanceOf(address(staking)), 1_000 ether, "victim intact");
        assertEq(attacker.rounds(), 1, "reentry happened");
    }
}
