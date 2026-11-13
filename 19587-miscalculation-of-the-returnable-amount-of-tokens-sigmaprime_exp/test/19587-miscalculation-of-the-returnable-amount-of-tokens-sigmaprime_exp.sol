// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, MockToken, VestingFixed} from "./19587-miscalculation-of-the-returnable-amount-of-tokens-sigmaprime.sol";

contract Finding19587Test is Test {
    function test_exploit_stopVesting_pays_claimed_amount_again() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vesting().returnAmountPaid(), 1_000 ether, "return is 1000");
        assertEq(e.token().balanceOf(address(e.sink())), 1_000 ether, "1000 taken");
        assertEq(e.token().balanceOf(address(e.vesting())), 0, "next vest empty");
        assertEq(e.nextVestBook(), 1_000 ether, "book still 1000");
    }

    function test_control_stopVesting_returns_zero() public {
        MockToken token = new MockToken();
        VestingFixed fixedVest = new VestingFixed(address(token));
        address owner = address(0xB0B);
        fixedVest.open(owner, 1_000 ether);
        token.mint(address(fixedVest), 1_000 ether);

        fixedVest.stopVesting();

        assertEq(fixedVest.returnAmountPaid(), 0, "nothing returned");
        assertEq(token.balanceOf(owner), 0, "owner paid 0");
        assertEq(token.balanceOf(address(fixedVest)), 1_000 ether, "next vest kept");
    }
}
