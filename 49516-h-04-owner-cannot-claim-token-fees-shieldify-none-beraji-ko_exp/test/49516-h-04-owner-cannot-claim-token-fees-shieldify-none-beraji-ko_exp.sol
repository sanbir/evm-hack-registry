// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, MockToken, StakingKoFixed} from "./49516-h-04-owner-cannot-claim-token-fees-shieldify-none-beraji-ko.sol";

contract TokenFeeClaimTest is Test {
    address internal constant OWNER = 0x0000000000000000000000000000000000000B0b;
    uint256 internal constant AMOUNT = 1000 ether;

    function test_exploit_ownerIsPaidZeroAndFeeStays() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paidVuln(), 0, "paid");
        assertEq(e.stuck(), AMOUNT, "stuck");
        assertEq(e.feeLeft(), 0, "wiped");
        assertEq(e.paidControl(), AMOUNT, "control paid");
        assertEq(e.token().balanceOf(address(e)), AMOUNT, "owner");
        assertEq(e.token().balanceOf(address(e.staking())), AMOUNT, "staking");
        assertEq(e.token().balanceOf(address(e.control())), 0, "control empty");
    }

    function test_control_cachedFeePaysTheOwner() public {
        MockToken token = new MockToken();
        StakingKoFixed staking = new StakingKoFixed(address(token), OWNER);
        token.mint(address(this), AMOUNT);
        token.approve(address(staking), AMOUNT);
        staking.accrue(AMOUNT);

        vm.prank(OWNER);
        staking.claimTokenFee(0);

        assertEq(token.balanceOf(OWNER), AMOUNT, "owner received N");
        assertEq(token.balanceOf(address(staking)), 0, "staking emptied");
    }
}
