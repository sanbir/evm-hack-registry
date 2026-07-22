// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./41089-h-03-sharebalance-bloating-eventually-blocks-curator-rewards.sol";

/*//////////////////////////////////////////////////////////////
    Phi -- shareBalance bloating eventually blocks curator rewards
    distribution (H-03, #41089)

    Cred._updateCuratorShareBalance sets a curator's share balance to 0 on a
    full sell instead of REMOVING the entry from the EnumerableMap. The map
    only ever grows. CuratorRewardsDistributor.distribute() enumerates EVERY
    entry ever added, including the permanent zero-balance orphans. Once
    enough distinct addresses have ever traded a cred's shares, this
    enumeration exceeds the block gas limit and distribute() permanently
    reverts, freezing that cred's curator rewards forever.

    This registry test runs with `isolate = true` (see foundry.toml) so each
    top-level call gets consensus-accurate (cold) storage-access gas
    metering -- exactly like separate transactions on mainnet, and exactly
    what the finding's own PoC achieves with `--isolate` (to "disable slot
    re-read discounts").

    - test_exploit: seeds SAMPLE_TRADERS orphaned entries via separate
      top-level calls, then measures distribute()'s real marginal gas cost
      per orphan and extrapolates to the finding's own ~4000-trader figure.
    - test_gasGrowsWithOrphanCount: control -- distribute() over an empty
      map is cheap; growing the orphan count measurably increases the cost,
      confirming the growth is driven by the enumeration itself.
//////////////////////////////////////////////////////////////////////////*/
contract CredShareBalanceBloatTest is Test {
    /// @notice HARM via the self-contained Exploit: seeds orphaned entries as
    ///         separate top-level calls (so `--isolate`/foundry.toml's isolate=true
    ///         gives each one genuinely cold storage access), then proves the
    ///         extrapolated real-world cost exceeds the block gas limit.
    function test_exploit() public {
        Exploit e = new Exploit();
        uint256 n = e.SAMPLE_TRADERS();
        for (uint256 i = 0; i < n; i++) {
            e.seedTrader();
        }
        e.run();

        assertGt(e.extrapolatedGas(), e.BLOCK_GAS_LIMIT(), "extrapolated cost exceeds the block gas limit");
    }

    /// @notice Control: distribute() over an EMPTY map is cheap and reverts nothing;
    ///         growing orphan count measurably grows the gas cost, confirming the
    ///         growth is driven by enumerating the ever-growing EnumerableMap.
    function test_gasGrowsWithOrphanCount() public {
        Cred cred = new Cred();
        CuratorRewardsDistributor distributor = new CuratorRewardsDistributor(cred);

        (uint256 touchedEmpty, uint256 gasEmpty) = distributor.distribute(1);
        assertEq(touchedEmpty, 0, "empty map: nothing to enumerate");
        assertLt(gasEmpty, 50_000, "empty map: distribute() is cheap");

        // Seed 10 orphaned entries as separate top-level calls (isolate = true).
        for (uint256 i = 0; i < 10; i++) {
            Relay r = new Relay(cred);
            r.buyThenSell(1, 1);
        }
        assertEq(cred.shareBalanceLength(1), 10, "10 permanent orphan entries");

        (uint256 touched10, uint256 gas10) = distributor.distribute(1);
        assertEq(touched10, 10, "distribute() enumerates all 10 orphans");
        assertGt(gas10, gasEmpty, "gas cost grows with orphan count");
    }
}
