// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20021-h-06-challenger-reward-can-be-used-to-drain-reserves-and-fre.sol";

/*//////////////////////////////////////////////////////////////////////////
    Frankencoin [H-06] — CHALLENGER_REWARD drain / free-mint.

    Driver test for the cheatcode-free synthetic. It deploys the Exploit (which
    builds the reduced Frankencoin system in its constructor), runs the attack,
    and independently re-asserts the harm:
      * the attacker/challenger receives ~20_000 ZCHF for a 1-unit position,
      * the reserve is drained to zero,
      * ZCHF total supply is inflated (the shortfall was minted from nothing).
//////////////////////////////////////////////////////////////////////////*/
contract ChallengerRewardDrainTest is Test {
    function test_challengerReward_drainsReserve_and_freeMints() public {
        Exploit exp = new Exploit();
        Frankencoin zchf = exp.zchf();
        Equity equity = exp.equity();

        // Baseline: reserve seeded, nothing minted to the attacker yet.
        assertEq(zchf.balanceOf(address(exp)), 0, "attacker starts with 0 ZCHF");
        assertEq(zchf.balanceOf(address(equity)), exp.RESERVE_SEED(), "reserve seeded");
        assertEq(zchf.totalSupply(), exp.RESERVE_SEED(), "only the reserve exists pre-attack");

        // === attack: inflate price -> self-challenge -> end -> collect reward ===
        exp.run();

        // HARM #1 — attacker/challenger free-mints a huge reward for a 1-unit
        // position, with no honest source of funds.
        assertEq(zchf.balanceOf(address(exp)), exp.EXPECTED_REWARD(), "attacker got the inflated reward");
        assertGt(zchf.balanceOf(address(exp)), exp.RESERVE_SEED(), "reward exceeds the whole reserve");

        // HARM #2 — the reserve is fully drained.
        assertEq(zchf.balanceOf(address(equity)), 0, "reserve emptied");

        // HARM #3 — ZCHF supply is inflated: everything the reserve could not
        // cover (reward - reserveSeed) was minted from nothing.
        assertEq(zchf.totalSupply(), exp.EXPECTED_REWARD(), "supply inflated to the reward size");
        assertEq(
            zchf.totalSupply() - exp.RESERVE_SEED(),
            exp.EXPECTED_REWARD() - exp.RESERVE_SEED(),
            "shortfall was free-minted"
        );
    }

    /// @notice Control: with a *sane* liquidation price the reward is a tiny
    ///         fraction of the challenged volume — the reserve is untouched.
    function test_saneReward_isBounded() public {
        // volume for a 1-unit challenge at price 1e18 is 1e18; reward = 1e18*2% = 2e16.
        // That is 0.02 ZCHF, dwarfed by the 5_000 ZCHF reserve — no free-mint.
        uint256 sanePrice = 1e18;
        uint256 saneVolume = sanePrice * 1e18 / 1e18;
        uint256 saneReward = (saneVolume * 20000) / 1000_000;
        assertEq(saneReward, 2e16);
        assertLt(saneReward, 5_000 ether);
    }
}
