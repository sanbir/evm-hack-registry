// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    FuroStreamFixed,
    Receiver
} from "./19584-miscalculation-of-amount-returnable-to-sender-sigmaprime-non.sol";

contract Finding19584Test is Test {
    function test_exploit_sender_takes_400_already_withdrawn() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e.sink())), 400 ether, "400 stolen");
        assertEq(e.furo().senderBalancePaid(), 900 ether, "sender paid 900");
        assertEq(e.token().balanceOf(address(e.furo())), 0, "other depositor wiped");
        assertEq(e.otherShares(), 400 ether, "other book still 400");
    }

    function test_control_sender_is_paid_unstreamed_shares_only() public {
        MockToken token = new MockToken();
        FuroStreamFixed fixedStream = new FuroStreamFixed(address(token));
        Receiver recipient = new Receiver();
        address sender = address(0xB0B);
        uint256 endTime = block.timestamp * 2;
        fixedStream.open(sender, address(recipient), 1_000 ether, 400 ether, 0, endTime);
        token.mint(address(fixedStream), 1_000 ether);

        fixedStream.cancelStream();

        assertEq(fixedStream.senderBalancePaid(), 500 ether, "fair sender");
        assertEq(token.balanceOf(sender), 500 ether, "sender balance");
        assertEq(token.balanceOf(address(recipient)), 100 ether, "recipient net");
        assertEq(token.balanceOf(address(fixedStream)), 400 ether, "other depositor kept");
    }
}
