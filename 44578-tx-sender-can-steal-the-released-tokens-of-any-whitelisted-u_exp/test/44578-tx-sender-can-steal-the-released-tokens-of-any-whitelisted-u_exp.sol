// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, GilToken, TokenVesting} from "./44578-tx-sender-can-steal-the-released-tokens-of-any-whitelisted-u.sol";

contract Finding44578Test is Test {
    function test_sender_takes_the_release() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 1000, "sender");
        assertEq(e.token().balanceOf(e.VICTIM()), 0, "victim");
        console2.log("sender received", e.token().balanceOf(address(e)));
        console2.log("victim received", e.token().balanceOf(e.VICTIM()));
    }

    function test_control_pays_the_receiver() public {
        GilToken token = new GilToken();
        TokenVesting vest = new TokenVesting(token);
        address victim = address(0xBEEF);
        vest.addToWhitelist(victim, 1000);
        token.mint(address(vest), 1000);
        uint256 paid = vest.releaseToReceiver(victim);
        assertEq(paid, 1000, "paid");
        assertEq(token.balanceOf(victim), 1000, "receiver");
        assertEq(token.balanceOf(address(this)), 0, "caller");
        console2.log("control receiver", token.balanceOf(victim));
    }
}
