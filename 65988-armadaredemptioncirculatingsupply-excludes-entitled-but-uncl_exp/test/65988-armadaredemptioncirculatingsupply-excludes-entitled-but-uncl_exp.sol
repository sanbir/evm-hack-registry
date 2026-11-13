// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, ArmadaRedemptionFixed, Holder, Carol} from
    "./65988-armadaredemptioncirculatingsupply-excludes-entitled-but-uncl.sol";

contract Finding65988Test is Test {
    function test_exploit_early_redeemers_take_carols_share() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.alicePayout(), 250_000e6, "alice overpaid");
        assertEq(e.bobPayout(), 250_000e6, "bob overpaid");
        assertEq(e.usdc().balanceOf(address(e)), 500_000e6, "early holders took the treasury");
        assertEq(e.usdc().balanceOf(address(e.carol())), 0, "carol received 0");
        assertFalse(e.carolPaid(), "carol redeem reverted");
    }

    function test_control_entitled_arm_stays_in_the_denominator() public {
        Token arm = new Token("ARM", 18);
        Token usdc = new Token("USDC", 6);
        Holder revenueLock = new Holder();
        Carol carol = new Carol();
        address treasury = address(uint160(0x7777));
        address crowdfund = address(uint160(0xCF00));
        uint256 total = 12_000_000 ether;
        ArmadaRedemptionFixed redemption = new ArmadaRedemptionFixed(
            arm, usdc, treasury, address(revenueLock), crowdfund, 1_800_000 ether
        );
        arm.mint(treasury, (total * 65) / 100);
        arm.mint(address(revenueLock), (total * 15) / 100);
        arm.mint(crowdfund, (total * 10) / 100);
        arm.mint(address(this), 1_200_000 ether);
        usdc.mint(address(redemption), 500_000e6);
        arm.approve(address(redemption), type(uint256).max);

        assertEq(redemption.circulatingSupply(), 3_000_000 ether, "carol counted");
        uint256 alice = redemption.redeem(600_000 ether);
        uint256 bob = redemption.redeem(600_000 ether);
        revenueLock.push(arm, address(carol), 1_800_000 ether);
        redemption.noteReleased(1_800_000 ether);
        uint256 carolGot = carol.redeemFixed(redemption, arm, 1_800_000 ether);

        assertEq(alice, 100_000e6, "alice fair");
        assertEq(bob, 100_000e6, "bob fair");
        assertEq(carolGot, 300_000e6, "carol fair");
        assertEq(usdc.balanceOf(address(carol)), 300_000e6, "carol paid");
        assertEq(usdc.balanceOf(address(redemption)), 0, "treasury cleared fairly");
    }
}
