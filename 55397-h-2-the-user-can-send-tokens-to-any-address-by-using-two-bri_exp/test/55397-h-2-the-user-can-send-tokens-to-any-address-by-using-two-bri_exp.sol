// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./55397-h-2-the-user-can-send-tokens-to-any-address-by-using-two-bri.sol";

contract BridgeBypassTransferLockTest is Test {
    function test_bridge_bypasses_transfer_lock() public {
        Exploit exp = new Exploit();
        Titn titn = exp.titn();

        exp.run();

        assertEq(titn.balanceOf(exp.USER2()), exp.AMOUNT(), "user2 got tokens via bridge");
        assertEq(titn.balanceOf(address(exp.user1())), 0, "user1 emptied");
    }
}
