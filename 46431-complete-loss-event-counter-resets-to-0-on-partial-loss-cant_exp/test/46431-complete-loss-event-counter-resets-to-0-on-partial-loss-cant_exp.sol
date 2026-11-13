// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, YieldVaultFixed} from
    "./46431-complete-loss-event-counter-resets-to-0-on-partial-loss-cant.sol";

contract Finding46431Test is Test {
    function test_exploit_partial_loss_resets_counter_and_pays_stale_position() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.eventsAfter(), 0, "reset");
        assertEq(e.taken(), 999999999999999999998, "took");
        assertEq(e.asset().balanceOf(address(e.vault())), 1, "dust");
    }

    function test_control_keeps_complete_loss_counter_and_pays_zero() public {
        Token asset = new Token();
        YieldVaultFixed vault = new YieldVaultFixed(asset);
        vault.seedStalePosition(address(this), 1000 ether);
        vault.burnOne();
        vault.notifyPartialLoss();
        assertEq(vault.completeLossEvents(), 4, "kept");
        uint256 paid = vault.withdraw();
        assertEq(paid, 0, "wiped");
        assertEq(asset.balanceOf(address(this)), 0, "user");
        assertEq(asset.balanceOf(address(vault)), 1000 ether - 1, "stays");
    }
}
