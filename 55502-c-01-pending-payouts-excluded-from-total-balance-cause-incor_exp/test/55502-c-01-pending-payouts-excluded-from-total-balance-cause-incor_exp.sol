// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Asset, Staking} from "./55502-c-01-pending-payouts-excluded-from-total-balance-cause-incor.sol";

contract StakingFixed is Staking {
    constructor(Asset token_, address staker) Staking(token_, staker) {}

    function totalAssets() public override returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        cachedAssets = bal - pendingTotal;
        return cachedAssets;
    }
}

contract Finding55502Test is Test {
    function test_exploit_withdraws_200_too_much() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 1100, "staker took 1100");
        assertEq(e.staking().pendingTotal(), 200, "200 still owed to the winner");
    }

    function test_control_subtracts_pending_payouts() public {
        Asset token = new Asset();
        address winner = address(0xBEEF);
        token.blockRecipient(winner);
        StakingFixed staking = new StakingFixed(token, address(this));
        token.mint(address(staking), 1100);
        bool paid = staking.transferPayout(address(token), winner, 200);
        uint256 out = staking.withdraw(address(this));
        assertFalse(paid, "payout failed");
        assertEq(out, 900, "control pays 900");
        assertEq(token.balanceOf(address(this)), 900, "staker received 900");
        assertEq(token.balanceOf(address(staking)), 200, "200 left for the winner");
    }
}
