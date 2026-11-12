// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    RewardDistributor,
    StandardToken
} from "./37590-non-standard-erc20-tokens-could-be-locked-in-the-contract-zo.sol";

contract NonStandardRewardLockTest is Test {
    address internal constant OWNER = 0x0000000000000000000000000000000000000B0b;
    uint256 internal constant AMOUNT = 1000 ether;
    uint256 internal constant FEE_STUCK = 900 ether;

    function test_exploit_nonStandardRewardsStayLocked() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stuckNoReturn(), AMOUNT, "no-return stuck");
        assertEq(e.ownerNoReturn(), 0, "owner no-return");
        assertEq(e.noReturn().balanceOf(address(e.distStuck())), AMOUNT, "distributor no-return");
        assertEq(e.stuckFee(), FEE_STUCK, "fee stuck");
        assertEq(e.ownerFee(), 0, "owner fee");
        assertEq(e.feeToken().balanceOf(address(e.distFee())), FEE_STUCK, "distributor fee");
        assertEq(e.paidControl(), AMOUNT, "control paid");
        assertEq(e.leftControl(), 0, "control leftover");
        assertEq(e.standard().balanceOf(OWNER), AMOUNT, "owner standard");
    }

    function test_control_standardTokenPaysTheOwner() public {
        StandardToken token = new StandardToken();
        RewardDistributor dist = new RewardDistributor(address(token), OWNER);
        token.mint(address(this), AMOUNT);
        token.transfer(address(dist), AMOUNT);

        dist.withdrawReward(AMOUNT);

        assertEq(token.balanceOf(OWNER), AMOUNT, "owner received N");
        assertEq(token.balanceOf(address(dist)), 0, "distributor emptied");
    }
}
