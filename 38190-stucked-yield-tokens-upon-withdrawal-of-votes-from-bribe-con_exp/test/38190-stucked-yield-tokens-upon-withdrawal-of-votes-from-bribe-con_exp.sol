// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38190-stucked-yield-tokens-upon-withdrawal-of-votes-from-bribe-con.sol";

contract StuckBribeRewardsTest is Test {
    /// @notice HARM: run() proves that after one of five equal voters
    ///         withdraws, only 80% of the deposited reward is distributable —
    ///         the withdrawn voter's 20% share is permanently stuck.
    function test_exploit_withdrawnVoterShare_getsStuck() public {
        Exploit e = new Exploit();
        e.run();

        MockRewardToken rt = e.rewardToken();
        assertEq(rt.balanceOf(address(e.bribe())), e.REWARD_AMOUNT() / 5, "20% must be stuck in the Bribe contract");
        assertEq(
            rt.balanceOf(address(0x1001)) + rt.balanceOf(address(0x1003)) + rt.balanceOf(address(0x1004)) + rt.balanceOf(address(0x1005)),
            (e.REWARD_AMOUNT() * 4) / 5,
            "the 4 remaining voters split exactly 80%"
        );
    }

    /// @notice Isolates the exact mechanism: withdraw() leaves totalVoting
    ///         unchanged, unlike deposit() which increments it symmetrically.
    function test_buggyWithdraw_doesNotDecrementTotalVoting() public {
        MockRewardToken rt = new MockRewardToken();
        Bribe bribe = new Bribe(address(this), address(rt));

        bribe.deposit(50e18, 1);
        bribe.deposit(50e18, 2);
        assertEq(bribe.totalVoting(), 100e18, "deposit should increment totalVoting");

        bribe.withdraw(50e18, 1);
        assertEq(bribe.totalVoting(), 100e18, "BUG: totalVoting stays 100e18 even though only 50e18 remains staked");
        assertEq(bribe.totalSupply(), 50e18, "totalSupply correctly drops to 50e18");
    }

    /// @notice Control: a fixed withdraw() that also decrements totalVoting
    ///         lets the full reward be distributed with nothing stuck.
    function test_control_fixedWithdraw_distributesFullReward() public {
        MockRewardToken rt = new MockRewardToken();
        FixedBribe bribe = new FixedBribe(address(this), address(rt));

        bribe.setOwner(1, address(0xAAA1));
        bribe.setOwner(2, address(0xAAA2));
        bribe.setOwner(3, address(0xAAA3));
        bribe.setOwner(4, address(0xAAA4));
        bribe.setOwner(5, address(0xAAA5));

        bribe.deposit(20e18, 1);
        bribe.deposit(20e18, 2);
        bribe.deposit(20e18, 3);
        bribe.deposit(20e18, 4);
        bribe.deposit(20e18, 5);

        bribe.withdraw(20e18, 2); // fixed: this now decrements totalVoting too
        assertEq(bribe.totalVoting(), 80e18, "fixed totalVoting correctly reflects the remaining 4 voters");

        rt.mint(address(this), 100e18);
        bribe.notifyRewardAmount(100e18);

        bribe.getRewardForOwner(1);
        bribe.getRewardForOwner(3);
        bribe.getRewardForOwner(4);
        bribe.getRewardForOwner(5);

        uint256 distributed = rt.balanceOf(address(0xAAA1)) +
            rt.balanceOf(address(0xAAA3)) +
            rt.balanceOf(address(0xAAA4)) +
            rt.balanceOf(address(0xAAA5));

        assertEq(distributed, 100e18, "with the fix, the full reward is distributable -- nothing stuck");
        assertEq(rt.balanceOf(address(bribe)), 0, "control: no reward tokens remain stuck in the contract");
    }
}
