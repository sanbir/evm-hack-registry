// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, StakingFixed, MockToken} from "./57923-reward-accumulation-manipulation-through-frequent-claims-mix.sol";

contract FrequentClaimTest is Test {
    uint256 internal constant WHEN = 1_700_000_000;

    function test_exploit_floorsTheHalfDayAndSecondClaimPaysZero() public {
        vm.warp(WHEN);
        Exploit e = new Exploit();
        e.run();

        assertEq(e.firstPaid(), 100 ether, "paid one floored day");
        assertEq(e.secondPaid(), 0, "second claim pays 0");
        assertEq(e.fair(), 150 ether, "fair 1.5 days");
        assertEq(e.burned(), 50 ether, "50 burned");
        assertEq(e.token().balanceOf(address(e)), 100 ether, "balance");
    }

    function test_control_precisionPaysTheFair150() public {
        vm.warp(WHEN);
        MockToken token = new MockToken();
        StakingFixed staking = new StakingFixed(address(token));
        token.mint(address(staking), 150 ether);
        staking.open(WHEN - (1 days + 12 hours));

        uint256 paid = staking.claim(address(this));
        assertEq(paid, 150 ether, "control pays the fair amount");
        assertEq(token.balanceOf(address(this)), 150 ether, "receiver");
    }
}
