// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {ArkoudaFixed, Exploit} from "./56419-user-can-claim-rewards-before-the-start-zokyo-none-cwbc-mark.sol";

contract Finding56419Test is Test {
    uint256 internal constant WHEN = 1 + 10 days;

    function setUp() public {
        vm.warp(WHEN);
    }

    function test_exploit_claims_before_start() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.stillNotStarted(), "start time still 0");
        assertEq(e.minted(), 100 ether, "100 ARK minted before start");
        assertEq(e.arkouda().balanceOf(address(0x1111111111111111111111111111111111111111)), 100 ether, "attacker");
        assertEq(e.arkouda().rewardGenerationStartTime(), 0, "never started");
    }

    function test_control_rejects_unset_start() public {
        ArkoudaFixed fixedA = new ArkoudaFixed();
        fixedA.mintNft(address(this), 1, 1);
        vm.expectRevert(bytes("not started"));
        fixedA.claimReward(1);
        assertEq(fixedA.balanceOf(address(this)), 0, "nothing minted");
    }
}
