// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./40985-malicious-request-could-burn-restoration-server-gas-fees-spe.sol";

contract Finding40985Test is Test {
    function test_contract_target_sticks_server_fee() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e.box())), 100, "stuck");
        assertEq(e.server().balance(), 0, "server spent");
        console2.log("stuck", e.token().balanceOf(address(e.box())));
        console2.log("server balance", e.server().balance());
    }
}
