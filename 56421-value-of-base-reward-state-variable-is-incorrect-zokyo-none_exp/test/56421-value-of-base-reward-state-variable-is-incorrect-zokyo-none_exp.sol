// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {ArkoudaFixed, Exploit} from "./56421-value-of-base-reward-state-variable-is-incorrect-zokyo-none.sol";

contract Finding56421Test is Test {
    function setUp() public {
        vm.warp(1 + 10 days);
    }

    function test_exploit_base_reward_overpays() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.arkouda().BASE_REWARD(), 10 ether, "constant is 10");
        assertEq(e.minted(), 100 ether, "10 days * 10");
        assertEq(e.spec(), 30 ether, "10 days * 3");
        assertEq(e.excess(), 70 ether, "70 ARK too many");
        assertEq(e.arkouda().balanceOf(address(0x1111111111111111111111111111111111111111)), 70 ether, "excess paid");
    }

    function test_control_three_per_day() public {
        ArkoudaFixed fixedA = new ArkoudaFixed();
        fixedA.mintNft(address(this), 1, 1);
        fixedA.claimReward(1);
        assertEq(fixedA.BASE_REWARD(), 3 ether, "spec constant");
        assertEq(fixedA.balanceOf(address(this)), 30 ether, "30 ARK");
    }
}
