// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Voter, FixedVoter} from
    "./57791-h-01-attacker-can-make-his-vepeg-nft-unpokeable-pashov-audit.sol";

contract Finding57791Test is Test {
    function test_exploit_stale_power_overpays() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.voter().usedWeights(e.TOKEN_ID()), 1_000e18, "stale 1000");
        assertEq(e.ve().balanceOfNFT(e.TOKEN_ID()), 500e18, "decayed 500");
        assertEq(e.voter().attackerPaid(), 1_500e18, "paid 1500");
        assertEq(e.voter().fairPay(), 1_000e18, "fair 1000");
        assertEq(e.voter().attackerPaid() - e.voter().fairPay(), 500e18, "over by 500");
        assertEq(e.reward().balanceOf(address(this)), 1_500e18, "received 1500");
        assertEq(e.fixedVoter().usedWeight(), 500e18, "control updated");
    }

    function test_control_poke_updates_power() public {
        FixedVoter fixedVoter = new FixedVoter();
        uint256 updated = fixedVoter.poke(500e18, 400e18, 600e18);
        assertEq(fixedVoter.usedWeight(), 500e18, "power is 500");
        assertEq(updated, 500e18, "split sums to 500");
    }
}
