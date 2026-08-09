// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    BobStaking,
    BobStakingFixed,
    DelegationSurrogate,
    MockERC20,
    IERC20
} from "./63718-c-02-stakes-not-forwarded-post-delegation-positions-unwithdr.sol";

contract StakesNotForwardedPostDelegationTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant DELEGATEE = 0x000000000000000000000000000000000000bEEF;

    uint256 internal constant STAKE1 = 100 ether;
    uint256 internal constant STAKE2 = 50 ether;

    // ── Vulnerable path: re-stake after delegation permanently freezes the position ──
    function test_exploit_reStakeAfterDelegation_positionFrozen() public {
        Exploit e = new Exploit();
        e.run();

        // Custody split the exit paths get wrong: surrogate holds only 100, staking holds 50.
        assertEq(e.surrogateHeld(), 100 ether, "surrogate holds only the pre-delegation portion");
        assertEq(e.stakingContractHeld(), 50 ether, "post-delegation re-stake stranded in the staking contract");
        assertEq(e.amountStakedRecorded(), 150 ether, "accounting shows the full 150 staked");

        // Both exit paths revert -> the position cannot be withdrawn.
        assertTrue(e.unbondReverted(), "unbond() reverts (surrogate holds 100 < 150)");
        assertTrue(e.instantWithdrawReverted(), "instantWithdraw() reverts (surrogate holds 100 < 150)");

        // Harm: the full 150-token position is frozen; recorded on the marker at SINK.
        assertEq(e.frozenAmount(), 150 ether, "150 tokens frozen (50 in staking + 100 in surrogate)");
        MockERC20 marker = MockERC20(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 150 ether, "marker records 150 LOCKED-STAKE at SINK");

        // The staked tokens are truly stranded: nothing reached the victim (this Exploit) on exit.
        MockERC20 token = MockERC20(e.tokenAddr());
        assertEq(token.balanceOf(address(e)), 0, "victim recovered nothing");
        assertEq(
            token.balanceOf(e.stakingAddr()) + token.balanceOf(e.surrogateAddr()),
            150 ether,
            "all 150 tokens locked across staking + surrogate"
        );
    }

    // ── Negative control: the fixed variant forwards the re-stake, so unbond succeeds ──
    function test_control_fixedForwardsReStake_unbondReturnsFull() public {
        MockERC20 token = new MockERC20("BOB Stake", "BOB");
        BobStakingFixed staking = new BobStakingFixed(address(token));

        token.mint(address(this), STAKE1 + STAKE2);
        token.approve(address(staking), type(uint256).max);

        staking.stake(STAKE1, address(this), 0);
        staking.alterGovernanceDelegatee(DELEGATEE);
        staking.stake(STAKE2, address(this), 0); // FIX forwards the 50 to the surrogate

        address surrogate = address(staking.storedSurrogates(DELEGATEE));

        // Single custody location: the surrogate holds the full 150, staking holds 0.
        assertEq(token.balanceOf(surrogate), 150 ether, "fixed: surrogate holds the full position");
        assertEq(token.balanceOf(address(staking)), 0, "fixed: nothing stranded in the staking contract");
        assertEq(staking.amountStakedOf(address(this)), 150 ether, "fixed: accounting shows 150");

        // unbond() succeeds and pulls the full 150 back — no revert, no freeze.
        uint256 returned = staking.unbond();
        assertEq(returned, 150 ether, "fixed: unbond returns the full 150");
        assertEq(token.balanceOf(address(staking)), 150 ether, "fixed: full position recovered by the staking contract");
        assertEq(staking.amountStakedOf(address(this)), 0, "fixed: position fully unbonded");
    }
}
