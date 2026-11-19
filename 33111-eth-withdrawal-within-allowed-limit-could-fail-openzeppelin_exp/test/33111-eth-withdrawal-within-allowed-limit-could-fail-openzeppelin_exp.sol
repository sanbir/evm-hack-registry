// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, MailboxFixed} from
    "./33111-eth-withdrawal-within-allowed-limit-could-fail-openzeppelin.sol";

contract Finding33111Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_second_withdrawal_inside_the_opening_cap_reverts() public {
        Exploit e = new Exploit();
        e.run{value: 1000 ether}();

        assertEq(address(e.mailbox()).balance, 940 ether, "40 ETH stayed in the mailbox");
        assertEq(e.mailbox().withdrawnAmountInWindow(), 60 ether, "only the first 60 was counted");
        assertEq(e.stuck().balanceOf(SINK), 40 ether, "40 ETH locked");
    }

    function test_control_uses_the_balance_from_the_start_of_the_window() public {
        MailboxFixed mailbox = new MailboxFixed();
        mailbox.seed{value: 1000 ether}();
        mailbox.withdraw(60 ether);
        mailbox.withdraw(40 ether);
        assertEq(address(mailbox).balance, 900 ether, "both withdrawals inside 10 percent paid");
        assertEq(mailbox.withdrawnAmountInWindow(), 100 ether, "window records 100");
        assertEq(mailbox.snapshotBalance(), 1000 ether, "cap base is the opening balance");
    }

    receive() external payable {}
}
