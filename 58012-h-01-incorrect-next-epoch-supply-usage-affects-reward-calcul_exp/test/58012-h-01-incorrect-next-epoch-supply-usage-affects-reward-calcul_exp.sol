// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    ExternalBribeFixed,
    RewardToken
} from "./58012-h-01-incorrect-next-epoch-supply-usage-affects-reward-calcul.sol";

contract Finding58012Test is Test {
    function test_next_epoch_supply_underpays() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.usedSupply(), 1, "lookup hits the next epoch checkpoint");
        assertEq(e.paid(), 100 ether, "voter is paid 100");
        assertEq(e.fair(), 1000 ether, "fair pay is 1000");
        assertEq(e.kept(), 900 ether, "900 stays in the bribe");
        assertEq(e.kitten().balanceOf(address(e)), 100 ether, "voter balance");
    }

    function test_control_uses_duration_minus_one() public {
        RewardToken kitten = new RewardToken();
        ExternalBribeFixed bribe = new ExternalBribeFixed(kitten);
        bribe.writeSupply(1, 100);
        bribe.writeSupply(1 + 7 days, 1000);
        bribe.setVoter(100, 1000 ether);
        kitten.mint(address(bribe), 1000 ether);
        uint256 paid = bribe.getReward(1);
        assertEq(paid, 1000 ether, "fair 1000");
        assertEq(kitten.balanceOf(address(this)), 1000 ether, "voter receives the pot");
        assertEq(kitten.balanceOf(address(bribe)), 0, "bribe is empty");
    }
}
