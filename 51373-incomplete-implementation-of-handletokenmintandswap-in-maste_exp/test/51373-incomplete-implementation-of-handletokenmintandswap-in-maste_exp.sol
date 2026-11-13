// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./51373-incomplete-implementation-of-handletokenmintandswap-in-maste.sol";

contract Finding51373Test is Test {
    function test_mint_and_swap_is_decoded_and_dropped() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.credited(), 0, "credited");
        assertEq(e.userBalance(), 0, "user");
        assertEq(e.controlBalance(), e.AMOUNT(), "control");
        assertEq(e.dropped(), e.AMOUNT(), "dropped");

        console2.log("credited");
        console2.log(e.credited());
        console2.log("user balance");
        console2.log(e.userBalance());
        console2.log("control minted");
        console2.log(e.controlBalance());
    }
}
