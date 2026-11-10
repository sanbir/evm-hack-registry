// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, ControlExploit} from "./12294-h-12-attacker-can-prevent-the-system-from-entering-step-5-du.sol";

contract Finding12294Test is Test {
    function test_exploit_blocks_step5_and_keeps_12000_usdc() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.controller().fundsReceived(1), 4, "fundsReceived");
        assertEq(e.controller().activeVaults(1), 3, "active");
        assertEq(e.controller().getAmountToDeposit(1, 2), 12_000e6, "deposit still queued");
        assertEq(e.token().balanceOf(address(e.controller())), 12_000e6, "controller still holds 12000");
        assertEq(e.token().balanceOf(e.VAULT2()), 0, "vault 2 received nothing");

        console2.log("stuck USDC", e.token().balanceOf(address(e.controller())));
        console2.log("fundsReceived", e.controller().fundsReceived(1));
        console2.log("activeVaults", e.controller().activeVaults(1));
        console2.log("queued deposit", e.controller().getAmountToDeposit(1, 2));
    }

    function test_control_enters_step5_and_moves_12000_usdc() public {
        ControlExploit c = new ControlExploit();
        c.run();

        assertEq(c.controller().fundsReceived(1), 3, "fundsReceived");
        assertEq(c.token().balanceOf(c.VAULT2()), 12_000e6, "vault 2 received 12000");
        assertEq(c.token().balanceOf(address(c.controller())), 0, "controller emptied");

        console2.log("vault2 USDC", c.token().balanceOf(c.VAULT2()));
        console2.log("control fundsReceived", c.controller().fundsReceived(1));
    }
}
