// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    ReceiptToken,
    UnwindingModule
} from "./55054-broken-accounting-when-cancelunwinding-is-called-one-epoch-a.sol";

contract Finding55054Test is Test {
    function test_exploit_next_epoch_locks_800() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stuck(), 800 ether, "800 locked in the module");
        assertEq(e.paid(), 0, "caller received nothing");
        assertTrue(e.settleReverted(), "settle reverted");
    }

    function test_control_same_epoch_cancel_pays_800() public {
        ReceiptToken receipt = new ReceiptToken();
        UnwindingModule book = new UnwindingModule(receipt);
        book.startUnwinding();
        receipt.mint(address(book), 800 ether);
        book.cancelSameEpoch();
        book.advanceEpoch();
        book.advanceEpoch();
        book.settle(address(this));
        assertEq(receipt.balanceOf(address(this)), 800 ether, "same-epoch cancel pays 800");
        assertEq(receipt.balanceOf(address(book)), 0, "module is empty");
        assertTrue(book.settled(), "settled");
    }
}
