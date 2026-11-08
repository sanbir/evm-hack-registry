// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    ReceiptToken,
    UnwindingModule,
    UnwindingModuleFixed,
    LockingController,
    User,
    IUnwinding
} from "./55055-lock-of-user-funds-due-to-zero-slashindex-update-spearbit-no.sol";

contract Finding55055Test is Test {
    function test_exploit_withdraw_reverts_while_controller_holds_N() public {
        Exploit e = new Exploit();
        e.run();

        uint256 n = e.LOCKED();
        assertEq(n, 1000 ether, "N is 1000 iUSD");
        assertEq(e.slashIndexAfter(), 0, "slashIndex stays 0");
        assertEq(e.paidOut(), 0, "withdraw paid 0");
        assertEq(e.withdrew(), false, "withdraw reverted");
        assertEq(e.heldAfter(), n, "controller still holds N");
        assertEq(e.userBalanceAfter(), 0, "user received 0");
        assertEq(e.receipt().balanceOf(address(e.locker())), n, "locker balance is N");
        assertEq(e.module().slashIndex(), 0, "module slashIndex is 0");

        emit log_named_uint("HARM locked iUSD wei", e.heldAfter());
        emit log_named_uint("HARM paid to user", e.paidOut());
        emit log_named_uint("HARM slashIndex", e.slashIndexAfter());
    }

    function test_control_reset_slashIndex_pays_user_N() public {
        ReceiptToken receipt = new ReceiptToken();
        UnwindingModuleFixed module = new UnwindingModuleFixed(receipt);
        LockingController locker = new LockingController(receipt, IUnwinding(address(module)));
        User user = new User(receipt);

        uint256 n = 1000 ether;
        uint256 bucket = 250 ether;
        receipt.mint(address(module), bucket);
        module.syncDeposits(bucket);
        receipt.mint(address(user), n);
        user.deposit(locker, n);

        assertEq(receipt.balanceOf(address(locker)), n, "pre-withdraw locker holds N");

        module.applyLosses(bucket);
        assertEq(module.slashIndex(), 1e18, "control restored slashIndex");
        assertEq(module.totalReceiptTokens(), 0, "bucket wiped");

        uint256 paid = locker.withdraw(address(user));
        assertEq(paid, n, "control pays N");
        assertEq(receipt.balanceOf(address(user)), n, "user receives N");
        assertEq(receipt.balanceOf(address(locker)), 0, "locker released N");

        emit log_named_uint("CONTROL slashIndex", module.slashIndex());
        emit log_named_uint("CONTROL user received", receipt.balanceOf(address(user)));
    }
}
