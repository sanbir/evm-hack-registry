// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./31585-c-01-attacker-can-drain-all-eth-from-ipseed-due-to-re-config.sol";

contract Finding31585Test is Test {
    function test_exploit_reconfigure_then_sell_drains_eth() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.minted(), 10 ether, "minted 10 at price 0");
        assertEq(e.eth().balanceOf(address(this)), 10 ether, "attacker received 10 ETH");
        assertEq(e.eth().balanceOf(address(e.seed())), 0, "IPSeed empty");
    }
}
