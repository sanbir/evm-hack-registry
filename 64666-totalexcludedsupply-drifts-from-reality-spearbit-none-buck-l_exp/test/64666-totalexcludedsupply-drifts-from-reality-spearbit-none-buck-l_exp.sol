// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    RewardsEngine,
    RewardsEngineFixed,
    HookToken,
    MiniToken
} from "./64666-totalexcludedsupply-drifts-from-reality-spearbit-none-buck-l.sol";

contract TotalExcludedSupplyDriftTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    address internal constant WHALE = 0x0000000000000000000000000000000000000011;
    address internal constant ALICE = 0x0000000000000000000000000000000000000022;

    uint256 internal constant WHALE_BAL = 1_000_000 ether;
    uint256 internal constant ALICE_BAL = 100_000 ether;
    uint256 internal constant REWARD_POOL = 50_000 ether;

    // ── Exploit: the drift bricks configureEpoch() and freezes the reward pool ──
    function test_exploit_excludedSupplyDrift_bricksEpochConfig() public {
        Exploit e = new Exploit();
        e.run();

        // The tracked excluded supply drifted high while real supply shrank.
        assertEq(e.staleExcludedSupply(), WHALE_BAL, "totalExcludedSupply stayed stale-high");
        assertEq(e.liveTotalSupply(), ALICE_BAL, "real totalSupply shrank after the burn");
        assertGt(
            e.staleExcludedSupply(),
            e.liveTotalSupply(),
            "tracked excluded supply now exceeds real total supply"
        );

        // configureEpoch() underflows and reverts -> epoch can never be configured.
        assertTrue(e.configureReverted(), "configureEpoch reverted (underflow DoS)");
        assertFalse(e.epochConfiguredFlag(), "epoch remains unconfigured");

        // The reward pool held by the engine is permanently frozen.
        assertEq(e.lockedRewards(), REWARD_POOL, "full reward pool locked");
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), REWARD_POOL, "marker records locked reward magnitude at SINK");

        // Directly re-prove the real revert against the deployed engine.
        RewardsEngine engine = RewardsEngine(e.engineAddr());
        vm.expectRevert(stdError.arithmeticError);
        engine.configureEpoch();
        assertFalse(engine.epochConfigured(), "engine never configured an epoch");

        // The real reward pool tokens are truly stranded in the engine.
        MiniToken pool = MiniToken(e.rewardPoolAddr());
        assertEq(pool.balanceOf(e.engineAddr()), REWARD_POOL, "reward pool stranded in engine");
    }

    // ── Negative control: the fixed hook keeps the denominator correct ──
    function test_control_fixedHook_configuresEpochWithCorrectDenominator() public {
        HookToken token = new HookToken("Strong", "STRX");
        RewardsEngineFixed engine = new RewardsEngineFixed(address(token));
        token.setEngine(address(engine));

        // Identical sequence to the exploit.
        token.mint(WHALE, WHALE_BAL);
        token.mint(ALICE, ALICE_BAL);
        engine.setAccountExcluded(WHALE, true);
        assertEq(engine.totalExcludedSupply(), WHALE_BAL, "excluded supply set on exclusion");

        token.burn(WHALE, WHALE_BAL);

        // The fix decremented totalExcludedSupply on the excluded outflow.
        assertEq(engine.totalExcludedSupply(), 0, "fixed hook kept excluded supply in sync");

        // configureEpoch now succeeds with the correct denominator (= ALICE_BAL).
        engine.configureEpoch();
        assertTrue(engine.epochConfigured(), "epoch configured under the fix");
        assertEq(engine.currentEligibleSupply(), ALICE_BAL, "correct eligible supply denominator");
    }
}
