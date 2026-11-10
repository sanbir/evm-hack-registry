// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, PowerBook, Pool} from "./40668-when-dp2pdtokenathbalance-is-increased-the-power-of-almost.sol";

contract Finding40668Test is Test {
    function test_stale_power_overpays_the_share() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.staleWeight(), 4500, "stale booster weight");
        assertEq(e.fairWeight(), 4000, "fair booster weight");
        assertEq(e.staleShare(), 4500, "share paid on stale power");
        assertEq(e.fairShare(), 4200, "fair share of the 10500 pot");
        assertGt(e.staleShare(), e.fairShare(), "overpaid");
        console2.log("stale weight", e.staleWeight());
        console2.log("fair weight", e.fairWeight());
        console2.log("stale share", e.staleShare());
        console2.log("fair share", e.fairShare());
    }

    function test_control_refreshes_power_before_payout() public {
        PowerBook book = new PowerBook();
        Pool poolB = new Pool(address(book));
        book.configure(address(this), 500, 1000);
        book.configure(address(poolB), 1000, 1000);
        poolB.stake(500);
        book.reCalBooster(address(this));

        uint256 paid = book.claim(address(this), address(poolB));
        assertEq(book.booster(address(this)), 4000, "refreshed weight");
        assertEq(paid, 4200, "fair share after refresh");
        assertEq(book.reward().balanceOf(address(this)), 4200, "paid 4200");
        console2.log("control weight", book.booster(address(this)));
        console2.log("control share", paid);
    }
}
