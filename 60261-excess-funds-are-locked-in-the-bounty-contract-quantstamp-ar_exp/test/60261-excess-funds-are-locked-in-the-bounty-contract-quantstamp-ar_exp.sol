// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, BountyToken, BountyV1Fixed} from "./60261-excess-funds-are-locked-in-the-bounty-contract-quantstamp-ar.sol";

contract Finding60261Test is Test {
    address internal constant FUNDER = 0x6666666666666666666666666666666666666666;
    address internal constant OWNER = 0x7777777777777777777777777777777777777777;

    function test_exploit_900_excess_locked() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.locked(), 900 ether, "900 of 1,000 excess locked");
        assertEq(e.token().balanceOf(address(e.bounty())), 900 ether, "still in the bounty");
        assertEq(e.token().balanceOf(address(e)), 100 ether, "owner withdrew only the 10% fee");
        assertEq(e.token().balanceOf(FUNDER), 1_000 ether, "funder got the initial amount");
    }

    function test_control_full_excess_withdrawable() public {
        BountyToken token = new BountyToken();
        BountyV1Fixed bounty = new BountyV1Fixed(token, OWNER);
        token.mint(address(this), 2_000 ether);
        token.approve(address(bounty), 2_000 ether);
        bounty.fund(1, FUNDER, 1_000 ether, 1_000 ether);
        bounty.closeBounty(1);
        bounty.burnAndWithdraw();
        assertEq(token.balanceOf(address(bounty)), 0, "nothing locked");
        assertEq(token.balanceOf(OWNER), 1_000 ether, "full excess paid out");
        assertEq(token.balanceOf(FUNDER), 1_000 ether, "initial refund");
    }
}
