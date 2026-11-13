// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, LendingFixed} from "./60243-inconsistent-use-of-basis-points-leading-to-enormous-fees-qu.sol";

contract Finding60243Test is Test {
    address internal constant FEE_TO = 0x3333333333333333333333333333333333333333;
    address internal constant LENDER = 0x5555555555555555555555555555555555555555;

    function test_exploit_grace_fee_is_4x() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.charged(), 4_000 ether, "fee is 4x the 1,000 debt");
        assertEq(e.token().balanceOf(FEE_TO), 4_000 ether, "fee sink");
        assertEq(e.charged() - 40 ether, 3_960 ether, "3,960 excess versus a true 4%");
    }

    function test_control_four_percent() public {
        Asset token = new Asset();
        LendingFixed lending = new LendingFixed(token, FEE_TO, LENDER);
        token.mint(address(this), 2_000 ether);
        token.approve(address(lending), type(uint256).max);
        lending.repay(1_000 ether);
        assertEq(token.balanceOf(FEE_TO), 40 ether, "true 4% is 40");
        assertEq(token.balanceOf(LENDER), 1_000 ether, "principal");
    }
}
