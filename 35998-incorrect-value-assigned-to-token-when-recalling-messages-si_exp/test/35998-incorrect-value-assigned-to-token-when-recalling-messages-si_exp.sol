// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./35998-incorrect-value-assigned-to-token-when-recalling-messages-si.sol";

contract Finding35998Test is Test {
    function test_recall_binds_token_to_the_user_and_1000_stays() public {
        Exploit e = new Exploit();
        e.run();

        console2.log("decoded is user", e.decoded() == address(e));
        console2.log("lost", e.lost());
        console2.log("stuck", e.stuck());

        assertEq(e.decoded(), address(e), "user");
        assertEq(e.lost(), 1_000 ether, "lost");
        assertEq(e.stuck(), 1_000 ether, "stuck");
        assertEq(e.token().balanceOf(address(e)), 0, "unpaid");
    }

    function test_control_refunds_1000_of_the_real_token() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("control paid", e.controlPaid());
        assertEq(e.controlPaid(), 1_000 ether, "paid");
        assertEq(e.token().balanceOf(address(e.vault())), 0, "empty");
    }
}
