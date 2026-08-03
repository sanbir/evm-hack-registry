// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "forge-std/Test.sol";

import {Syndicate} from "../src/syndicate/Syndicate.sol";
import {MockERC20} from "../src/testing/MockERC20.sol";
import {MockStakeHouseUniverse} from "../src/testing/MockStakeHouseUniverse.sol";
import {MockSlotRegistry} from "../src/testing/MockSlotRegistry.sol";
import {IStakeHouseUniverse} from "@blockswaplab/stakehouse-contract-interfaces/contracts/interfaces/IStakeHouseUniverse.sol";
import {ISlotSettlementRegistry} from "@blockswaplab/stakehouse-contract-interfaces/contracts/interfaces/ISlotSettlementRegistry.sol";

/// @dev Thin harness that ONLY overrides the two external Stakehouse-core
/// address getters, exactly as the audited repo's own `SyndicateMock` does
/// (contracts/testing/syndicate/SyndicateMock.sol). Every reward/unstake
/// accounting path (`stake`, `unstake`, `_claimAsStaker`,
/// `calculateUnclaimedFreeFloatingETHShare`, `updateAccruedETHPerShares`) is
/// inherited UNCHANGED from the real audited `Syndicate.sol`. The knot registry
/// and sETH token are the real external Stakehouse core, replaced by the repo's
/// own mocks (MockStakeHouseUniverse / MockSlotRegistry / MockERC20).
contract SyndicateHarness is Syndicate {
    address public uni;
    address public slotReg;

    constructor(address _uni, address _slotReg, address _owner, bytes[] memory _keys) {
        uni = _uni;
        slotReg = _slotReg;
        // Same internal initializer the production proxy calls; registers the knot(s).
        _initialize(_owner, 0, new address[](0), _keys);
    }

    function getStakeHouseUniverse() internal view override returns (IStakeHouseUniverse) {
        return IStakeHouseUniverse(uni);
    }

    function getSlotRegistry() internal view override returns (ISlotSettlementRegistry) {
        return ISlotSettlementRegistry(slotReg);
    }
}

/// @notice Real-source PoC for Code4rena 2022-11-stakehouse H-04:
/// `unstake` pays out owed ETH and re-snapshots `sETHUserClaimForKnot` using the
/// FULL pre-unstake balance, then reduces `sETHStakedBalanceForKnot` WITHOUT
/// recomputing the claim snapshot. The staker is left with an inflated
/// "already-claimed" debt against a smaller remaining stake, so on the next
/// reward round they are paid strictly LESS than an identically-positioned
/// honest staker (and, when the debt exceeds the fresh entitlement, their
/// remaining position is fully bricked by an arithmetic underflow).
contract PoC_43027_StaleClaimSnapshot is Test {
    bytes internal constant KNOT = hex"0102030405";
    address internal constant HOUSE = address(0xBEEF);

    address internal constant ALICE = address(0xA11CE); // stakes 5, unstakes 3 -> bug victim
    address internal constant CAROL = address(0xCA201); // stakes a fresh 2 -> honest control

    MockERC20 internal sETH;
    MockStakeHouseUniverse internal uni;
    MockSlotRegistry internal slot;
    SyndicateHarness internal syndicate;

    function _keys() internal pure returns (bytes[] memory k) {
        k = new bytes[](1);
        k[0] = KNOT;
    }

    function _amt(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function setUp() public {
        // Real external Stakehouse core doubles (the audited repo's own mocks).
        uni = new MockStakeHouseUniverse();
        slot = new MockSlotRegistry();
        sETH = new MockERC20("sETH", "sETH", address(this));

        uni.setAssociatedHouseForKnot(KNOT, HOUSE);
        slot.setShareTokenForHouse(HOUSE, address(sETH));

        // Deploy the REAL Syndicate logic (via the thin getter-override harness).
        syndicate = new SyndicateHarness(address(uni), address(slot), address(this), _keys());

        // Fund the two stakers with real sETH.
        sETH.transfer(ALICE, 10 ether);
        sETH.transfer(CAROL, 10 ether);
    }

    /// EIP-1559 tips arrive at the syndicate (fee recipient forwards ETH).
    function _accrue(uint256 balanceTarget) internal {
        vm.deal(address(syndicate), balanceTarget);
    }

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        sETH.approve(address(syndicate), amount);
        syndicate.stake(_keys(), _amt(amount), who);
        vm.stopPrank();
    }

    function testUnstakerIsShortedRelativeToHonestStaker() public {
        // --- Phase 0: Alice stakes 5 sETH (accumulator = 0, debt = 0) ---
        _stake(ALICE, 5 ether);
        assertEq(syndicate.sETHStakedBalanceForKnot(KNOT, ALICE), 5 ether);
        assertEq(syndicate.sETHUserClaimForKnot(KNOT, ALICE), 0);

        // --- Phase 1: 8 ETH of rewards arrive; free-floating half = 4 ETH ---
        _accrue(8 ether);

        // Alice unstakes 3 sETH. `_claimAsStaker` pays her the 4 ETH owed on 5
        // shares and snapshots her claim-debt = accPerShare * 5 shares. The
        // balance is then cut to 2 sETH but the debt is NOT recomputed.
        uint256 aliceEthAfterP1;
        {
            uint256 before = ALICE.balance;
            vm.prank(ALICE);
            syndicate.unstake(ALICE, ALICE, _keys(), _amt(3 ether));
            aliceEthAfterP1 = ALICE.balance - before;
        }
        assertEq(aliceEthAfterP1, 4 ether, "phase-1 claim on 5 shares");
        assertEq(syndicate.sETHStakedBalanceForKnot(KNOT, ALICE), 2 ether, "alice now holds 2 sETH");
        // BUG: debt is 4 ETH (accPerShare * 5), i.e. based on the OLD 5-share
        // balance. A correct implementation would set it to accPerShare * 2 = 1.6 ETH.
        assertEq(syndicate.sETHUserClaimForKnot(KNOT, ALICE), 4 ether, "stale inflated claim-debt");

        // --- Phase 1b: Carol stakes a FRESH 2 sETH at the same accumulator ---
        // Her debt is correctly snapshotted at accPerShare * 2 = 1.6 ETH.
        _stake(CAROL, 2 ether);
        assertEq(syndicate.sETHStakedBalanceForKnot(KNOT, CAROL), 2 ether);
        assertEq(syndicate.sETHUserClaimForKnot(KNOT, CAROL), 1.6 ether, "correct claim-debt for 2 shares");

        // Alice and Carol now hold the IDENTICAL 2-sETH position.
        assertEq(
            syndicate.sETHStakedBalanceForKnot(KNOT, ALICE),
            syndicate.sETHStakedBalanceForKnot(KNOT, CAROL),
            "identical remaining stake"
        );

        // --- Phase 2: more rewards arrive; both claim over the SAME window ---
        _accrue(24 ether);

        uint256 aliceClaim;
        {
            uint256 before = ALICE.balance;
            vm.prank(ALICE);
            syndicate.claimAsStaker(ALICE, _keys());
            aliceClaim = ALICE.balance - before;
        }

        uint256 carolClaim;
        {
            uint256 before = CAROL.balance;
            vm.prank(CAROL);
            syndicate.claimAsStaker(CAROL, _keys());
            carolClaim = CAROL.balance - before;
        }

        // Concrete real-ETH harm: identical 2-sETH positions over an identical
        // reward window, yet Alice is paid 2.6 ETH while Carol is paid 5.0 ETH.
        assertEq(aliceClaim, 2.6 ether, "bugged staker underpaid");
        assertEq(carolClaim, 5.0 ether, "honest staker fair pay");
        assertLt(aliceClaim, carolClaim, "unstaker is shorted");

        // The shortfall equals accPerShare_1 * (5 - 2) shares / PRECISION = the
        // 3 shares she already unstaked and was already paid for = 2.4 ETH stolen
        // from her rightful future rewards.
        assertEq(carolClaim - aliceClaim, 2.4 ether, "Alice shorted by exactly 2.4 ETH");
    }

    /// When the stale debt exceeds the fresh entitlement on the remaining stake,
    /// the victim's position is fully bricked: BOTH `claimAsStaker` and any further
    /// `unstake` revert on the underflow inside `calculateUnclaimedFreeFloatingETHShare`,
    /// permanently freezing the remaining sETH + all its future rewards.
    function testStaleDebtBricksRemainingPosition() public {
        _stake(ALICE, 5 ether);
        _accrue(8 ether);

        vm.prank(ALICE);
        syndicate.unstake(ALICE, ALICE, _keys(), _amt(3 ether));

        // Remaining 2-share entitlement (accPerShare * 2 = 1.6 ETH) is LESS than
        // the stale 4 ETH debt -> userShare - claim underflows -> revert.
        vm.expectRevert(); // arithmetic underflow (Solidity 0.8 checked math)
        syndicate.calculateUnclaimedFreeFloatingETHShare(KNOT, ALICE);

        // A fresh honest 2-sETH staker at the same accumulator is unaffected.
        _stake(CAROL, 2 ether);
        uint256 carolUnclaimed = syndicate.calculateUnclaimedFreeFloatingETHShare(KNOT, CAROL);
        assertEq(carolUnclaimed, 0, "honest fresh staker starts even");

        // Alice cannot even withdraw her remaining sETH: unstake also routes
        // through the reverting claim path, so her 2 sETH is frozen.
        vm.prank(ALICE);
        vm.expectRevert();
        syndicate.unstake(ALICE, ALICE, _keys(), _amt(2 ether));
    }

    receive() external payable {}
}
