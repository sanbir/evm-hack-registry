// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, SapienToken, SapienStakingFixed} from
    "./62035-missing-balance-deduction-in-unstaking-functions-allows-cont.sol";

contract Finding62035Test is Test {
    function test_exploit_unstake_repeats() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e)), 400e18, "withdrew 400");
        assertEq(e.token().balanceOf(address(e.staking())), 600e18, "pool 600");
        (uint256 still, bool active) = e.staking().stakes(1);
        assertEq(still, 100e18, "stake not deducted");
        assertTrue(active, "still active");
    }

    function test_control_unstakes_once() public {
        SapienToken token = new SapienToken();
        SapienStakingFixed fixedStaking = new SapienStakingFixed(token);
        token.mint(address(fixedStaking), 900e18);
        token.mint(address(this), 100e18);
        token.approve(address(fixedStaking), 100e18);
        fixedStaking.stake(1, 100e18);
        fixedStaking.unstake(1);

        assertEq(token.balanceOf(address(this)), 100e18, "paid once");
        assertEq(token.balanceOf(address(fixedStaking)), 900e18, "others intact");
        (uint256 still, bool active) = fixedStaking.stakes(1);
        assertEq(still, 0, "deducted");
        assertFalse(active, "closed");

        bool secondPaid = true;
        try fixedStaking.unstake(1) {
            secondPaid = true;
        } catch {
            secondPaid = false;
        }
        assertFalse(secondPaid, "second unstake reverts");
    }
}
