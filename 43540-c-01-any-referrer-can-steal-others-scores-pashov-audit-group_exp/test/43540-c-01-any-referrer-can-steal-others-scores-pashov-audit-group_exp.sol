// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, BunniTokenFixed} from "./43540-c-01-any-referrer-can-steal-others-scores-pashov-audit-group.sol";

contract Finding43540Test is Test {
    function test_exploit_dust_mint_steals_referrer_score() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.scoreABefore(), 100 ether, "victim score was 100");
        assertEq(e.scoreAAfter(), 0, "victim score cleared");
        assertEq(e.scoreBAfter(), 100 ether + 1, "attacker score");
        assertEq(e.paid(), 100 ether + 1, "rewards paid");
        assertEq(e.reward().balanceOf(address(e)), 100 ether + 1, "attacker balance");
    }

    function test_control_existing_referrer_is_kept() public {
        BunniTokenFixed token = new BunniTokenFixed();
        address victim = address(0xA11CE);
        token.mint(victim, 100 ether, 0xA);
        token.mint(victim, 1, 0xB);

        assertEq(token.scoreOf(0xA), 100 ether + 1, "score stays with A");
        assertEq(token.scoreOf(0xB), 0, "B receives nothing");
        assertEq(token.referrerOf(victim), 0xA, "referrer unchanged");
    }
}
