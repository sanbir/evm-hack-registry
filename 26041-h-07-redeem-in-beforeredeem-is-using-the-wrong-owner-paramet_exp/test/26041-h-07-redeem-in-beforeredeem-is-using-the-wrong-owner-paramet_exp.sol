// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./26041-h-07-redeem-in-beforeredeem-is-using-the-wrong-owner-paramet.sol";

/*//////////////////////////////////////////////////////////////
    Maia DAO — [H-07] beforeRedeem wrong owner. Finding 26041
    (Code4rena 2023-05, reporter bin2chen) — HIGH
//////////////////////////////////////////////////////////////*/
contract MaiaBeforeRedeemOwnerTest is Test {
    Exploit exp;

    function setUp() public {
        exp = new Exploit();
    }

    function test_control_correct_owner_gets_rewards() public {
        RewardToken rwd = new RewardToken();
        RewardToken und = new RewardToken();
        Flywheel fw = new Flywheel(rwd);
        TalosStrategyStaked s = new TalosStrategyStaked(fw, und);
        s.mintShares(address(this), 100 ether);
        fw.notifyRewards(100 ether);
        s.redeemFixed(100 ether, address(0xBEEF), address(this));
        uint256 claimed = fw.claim(address(this));
        assertEq(claimed, 100 ether, "correct accrue pays owner full yield");
    }

    function test_wrong_owner_param_strands_rewards() public {
        exp.run();
        emit log_named_uint("owner claimed", exp.ownerClaimed());
        emit log_named_uint("stranded RWD", exp.strandedInFlywheel());
        assertEq(exp.ownerClaimed(), 0, "owner lost rewards");
        assertEq(exp.strandedInFlywheel(), 100 ether, "yield stranded");
    }
}
