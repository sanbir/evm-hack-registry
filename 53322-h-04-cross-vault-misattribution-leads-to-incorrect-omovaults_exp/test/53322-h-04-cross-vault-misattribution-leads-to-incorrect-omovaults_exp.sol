// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Agent, VaultFixed} from
    "./53322-h-04-cross-vault-misattribution-leads-to-incorrect-omovaults.sol";

contract Finding53322Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_counts_the_other_vault() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vault().reported(), 200 ether, "reports 200");
        assertEq(e.marker().balanceOf(SINK), 60 ether, "60 too much");
    }

    function test_control_counts_only_this_vault() public {
        Agent agent = new Agent();
        VaultFixed vault = new VaultFixed(agent);
        assertEq(vault.totalAssets(), 140 ether, "100 cash plus this vault's 40");
    }
}
