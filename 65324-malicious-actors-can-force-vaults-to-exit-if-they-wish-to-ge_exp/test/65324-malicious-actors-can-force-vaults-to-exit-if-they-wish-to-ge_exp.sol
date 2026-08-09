// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    StakeManager,
    StakeManagerFixed,
    StakeVaultDouble,
    MiniToken
} from "./65324-malicious-actors-can-force-vaults-to-exit-if-they-wish-to-ge.sol";

contract ForceVaultExitDoSTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant BLOCK_GAS_LIMIT = 30_000_000;
    uint256 internal constant REWARD_AMOUNT = 5_000 ether;

    // ─────────────────────────────────────────────────────────────────────────
    // EXPLOIT: attacker inflates vaults[victim] with same-codehash vaults so
    // redeemRewards(victim) can no longer complete within a 30M-gas block.
    // The victim's 5,000 KARMA of accrued rewards are permanently locked.
    // ─────────────────────────────────────────────────────────────────────────
    function test_exploit_forcedVaultInflation_locksRewards() public {
        Exploit e = new Exploit();
        e.run();

        // The attacker registered many vaults for the victim (1 honest + spam).
        assertGt(e.victimVaultCount(), 1000, "attacker inflated victim's vault array");

        // redeemRewards(victim) could NOT complete within a 30M-gas block.
        assertTrue(e.redeemReverted(), "redeemRewards should OOG under block gas limit");

        // The victim received nothing: their rewards are locked in the contract.
        assertEq(e.victimRewardBalanceAfter(), 0, "victim could not redeem any rewards");

        // The real reward pool is stranded in the manager (victim is owed it).
        MiniToken reward = MiniToken(e.rewardTokenAddr());
        assertEq(reward.balanceOf(e.stakeManagerAddr()), REWARD_AMOUNT, "rewards stranded in manager");

        // Locked magnitude recorded on the marker at the SINK.
        assertEq(e.lockedRewards(), REWARD_AMOUNT, "locked reward magnitude");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), REWARD_AMOUNT, "SINK marker records locked rewards");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEGATIVE CONTROL 1 (same vulnerable code, no spam): with only the honest
    // vault present, redeemRewards succeeds and the victim receives their rewards.
    // Proves the DoS is caused by the array inflation, not the setup.
    // ─────────────────────────────────────────────────────────────────────────
    function test_control_noSpam_redeemSucceeds() public {
        address victim = address(uint160(uint256(keccak256("STATUSL2_VICTIM"))));

        MiniToken reward = new MiniToken("Karma", "KARMA");
        StakeManager sm = new StakeManager(address(reward), address(this));

        StakeVaultDouble probe = new StakeVaultDouble(victim);
        sm.setTrustedCodehash(address(probe).codehash, true);

        StakeVaultDouble honest = new StakeVaultDouble(victim);
        honest.register(address(sm));
        sm.__seedAccruedRewards(address(honest), REWARD_AMOUNT, 1e27);
        reward.mint(address(sm), REWARD_AMOUNT);

        // With a single vault the loop is trivial; redeem succeeds within 30M gas.
        (bool ok, bytes memory ret) =
            address(sm).call{ gas: BLOCK_GAS_LIMIT }(abi.encodeWithSelector(StakeManager.redeemRewards.selector, victim));
        assertTrue(ok, "redeem should succeed without spam");
        uint256 redeemed = abi.decode(ret, (uint256));

        assertEq(redeemed, REWARD_AMOUNT, "victim redeemed full accrued rewards");
        assertEq(reward.balanceOf(victim), REWARD_AMOUNT, "victim received rewards");
        assertEq(reward.balanceOf(address(sm)), 0, "pool fully paid out");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEGATIVE CONTROL 2 (fixed code): the post-fix registerVault is factory-only,
    // so an attacker cannot register vaults at all → no inflation possible.
    // ─────────────────────────────────────────────────────────────────────────
    function test_control_fixed_attackerCannotRegister() public {
        address victim = address(uint160(uint256(keccak256("STATUSL2_VICTIM"))));
        address factory = address(0xFAC7);

        StakeManagerFixed sm = new StakeManagerFixed(address(this), factory);

        StakeVaultDouble mal = new StakeVaultDouble(victim);
        sm.setTrustedCodehash(address(mal).codehash, true);

        // Attacker (this test contract, not the factory) tries to register: reverts.
        vm.expectRevert(StakeManagerFixed.StakeManager__Unauthorized.selector);
        sm.registerVault(address(mal));

        // Only the factory can register, so the array cannot be attacker-inflated.
        vm.prank(factory);
        sm.registerVault(address(mal));
        assertEq(sm.getVaults(victim).length, 1, "only factory-registered vaults exist");
    }
}
