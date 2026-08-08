// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    PledgeManager,
    PledgeManagerFixed,
    VictimActor
} from "./61175-attacker-can-make-pledge-on-behalf-of-users-if-those-users.sol";

contract Finding61175Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_attacker_pledges_on_behalf_of_victim() public {
        Exploit e = new Exploit();
        e.run();

        uint256 amount = e.PLEDGE_AMOUNT();

        // Victim's stablecoin was fully spent without consent.
        assertEq(e.victimBalanceBefore(), amount, "victim funded");
        assertEq(e.victimBalanceAfter(), 0, "victim drained without consent");

        // The stolen tokens ended up with the attacker.
        assertEq(e.attackerProfit(), amount, "attacker captured victim funds");

        MiniToken stable = e.stable();
        assertEq(stable.balanceOf(ATTACKER), amount, "attacker balance == stolen amount");

        // Concrete harm magnitude: 1,000e6 stablecoin (6 decimals).
        assertEq(amount, 1_000e6, "harm magnitude");
    }

    function test_control_fixed_reverts_when_caller_not_signer() public {
        // Reproduce the SAME preconditions and the SAME attack against the
        // fixed manager, and assert the victim keeps their funds.
        MiniToken stable = new MiniToken("USD Stable", "USDX");
        PledgeManagerFixed manager = new PledgeManagerFixed(address(stable));
        VictimActor victim = new VictimActor();

        uint256 amount = 1_000e6;
        stable.mint(address(victim), amount);
        victim.approveManager(stable, address(manager));

        PledgeManagerFixed.PledgeData memory data = PledgeManagerFixed.PledgeData({
            signer: address(victim),
            stablecoinAmount: amount,
            usePermit: false,
            permitV: 0,
            permitR: bytes32(0),
            permitS: bytes32(0)
        });

        // Attacker (this test contract, != victim) tries the same call: reverts.
        vm.expectRevert(PledgeManagerFixed.MsgSenderNotSigner.selector);
        manager.pledge(data);

        // Victim retains all funds; nothing stolen.
        assertEq(stable.balanceOf(address(victim)), amount, "victim funds safe under fix");
    }
}
