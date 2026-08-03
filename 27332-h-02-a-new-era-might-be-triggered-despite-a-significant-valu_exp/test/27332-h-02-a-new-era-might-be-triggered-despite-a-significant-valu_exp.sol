// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/reserve/target/p1/StRSRVotes.sol";
import "../src/reserve/target/interfaces/IMain.sol";
import "../src/reserve/target/poc/PoCEnv.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Real-source reproduction of Reserve H-02 (Code4rena 2023-06, commit c4ec2473).
///         Deploys the REAL StRSRP1Votes. A single follow-on RSR seizure of only 10% pushes
///         the stake rate across MAX_STAKE_RATE, triggering beginEra() which wipes the entire
///         current era even though the staker still holds a large position. seizeRSR reduces
///         stakeRSR (the RSR backing) but never totalStakes (the share supply), so the rate
///         totalStakes*1e18/stakeRSR grows until a small seizure crosses the cap.
contract PoC_27332 is Test {
    StRSRP1Votes internal stRSR;
    MiniRSR internal rsr;
    PoCMain32 internal main;
    Staker internal victim;

    // This test contract plays the backingManager (the only address allowed to seize).
    function setUp() public {
        rsr = new MiniRSR();
        main = new PoCMain32(IERC20(address(rsr)), address(this));

        StRSRP1Votes impl = new StRSRP1Votes();
        bytes memory initData = abi.encodeWithSignature(
            "init(address,string,string,uint48,uint192,uint192)",
            address(main),
            "Staked RSR",
            "stRSR",
            uint48(1209600), // unstakingDelay
            uint192(0), // rewardRatio (no reward payout interference)
            uint192(0) // withdrawalLeak
        );
        stRSR = StRSRP1Votes(address(new ERC1967Proxy(address(impl), initData)));

        victim = new Staker();
        rsr.mint(address(victim), 2 ether);
    }

    function test_small_seizure_wipes_large_staked_position() public {
        uint256 eraBefore = stRSR.currentEra();

        // The victim stakes 1 RSR: 1e18 stRSR minted at rate 1.0.
        victim.approveAndStake(IERC20(address(rsr)), address(stRSR), 1 ether);

        // A large seizure leaves the stake pool barely solvent: stakeRSR ~1.05e9 qRSR, which
        // drives stakeRate to ~9.52e26, just under MAX_STAKE_RATE (1e27). No era reset yet.
        uint256 firstSeizure = 1 ether - 1_050_000_000;
        stRSR.seizeRSR(firstSeizure);
        assertEq(stRSR.currentEra(), eraBefore, "no era reset after the large seizure");

        // The victim keeps staking as normal usage resumes. Because the rate is now ~9.52e26,
        // staking 1 RSR mints ~9.52e26 stRSR: a large, valuable position.
        victim.approveAndStake(IERC20(address(rsr)), address(stRSR), 1 ether);
        uint256 victimStakeBefore = stRSR.balanceOf(address(victim));
        assertGt(victimStakeBefore, 1e26, "victim now holds a large stRSR position");
        assertEq(stRSR.totalSupply(), victimStakeBefore, "victim owns the whole era");

        // The RSR still backing that position (orphaned once the era resets).
        uint256 rsrHeld = rsr.balanceOf(address(stRSR));
        assertGt(rsrHeld, 0.9 ether, "significant RSR value is still held for stakers");

        // A mere 10% follow-on seizure pushes stakeRate just over MAX_STAKE_RATE, and the
        // REAL beginEra() branch fires -> the entire current era is wiped.
        uint256 secondSeizure = rsrHeld / 10;
        stRSR.seizeRSR(secondSeizure);

        // === Harm: the victim's large position is gone despite ~90% of value still present ===
        assertGt(stRSR.currentEra(), eraBefore, "a NEW era was triggered");
        assertEq(stRSR.totalSupply(), 0, "entire era wiped");
        assertEq(stRSR.balanceOf(address(victim)), 0, "victim lost their entire stake");
    }
}
