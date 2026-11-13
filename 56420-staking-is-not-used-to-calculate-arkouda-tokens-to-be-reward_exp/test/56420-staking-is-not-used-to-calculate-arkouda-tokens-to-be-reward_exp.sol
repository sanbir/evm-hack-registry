// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {ArkoudaFixed, Exploit} from "./56420-staking-is-not-used-to-calculate-arkouda-tokens-to-be-reward.sol";

contract Finding56420Test is Test {
    function setUp() public {
        vm.warp(1 + 10 days);
    }

    function test_exploit_unstaked_holder_is_paid() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.unstakedMint(), 100 ether, "unstaked minted 100");
        assertEq(e.stakedMint(), 100 ether, "staked minted the same 100");
        assertEq(e.arkouda().stakeCalls(), 1, "only the second nft was staked");
        assertEq(e.arkouda().balanceOf(address(0x1111111111111111111111111111111111111111)), 100 ether, "paid out");
    }

    function test_control_unstaked_claim_reverts() public {
        ArkoudaFixed fixedA = new ArkoudaFixed();
        fixedA.mintNft(address(this), 1, 1);
        vm.expectRevert(bytes("not staked"));
        fixedA.claimReward(1);
        assertEq(fixedA.balanceOf(address(this)), 0, "unstaked paid nothing");

        fixedA.mintNft(address(this), 2, 1);
        fixedA.stakeCBWC(2);
        fixedA.claimReward(2);
        assertEq(fixedA.balanceOf(address(this)), 100 ether, "staker still paid");
    }
}
