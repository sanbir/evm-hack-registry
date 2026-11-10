// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, EarningBook} from "./40669-when-the-poolowner-gets-shared-earnings-the-power-of-that-po.sol";

contract Finding40669Test is Test {
    address internal constant PAYER = address(0xB0B);

    function test_stale_fs_pays_the_wrong_reward() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.staleFs(), 50, "stale fs hundredths");
        assertEq(e.fairFs(), 75, "fair fs hundredths");
        assertEq(e.staleReward(), 100, "reward on stale power");
        assertEq(e.fairReward(), 150, "fair reward");
        console2.log("stale fs hundredths", e.staleFs());
        console2.log("fair fs hundredths", e.fairFs());
        console2.log("stale reward", e.staleReward());
        console2.log("fair reward", e.fairReward());
    }

    function test_control_updates_power_before_payout() public {
        EarningBook book = new EarningBook(address(this));
        book.configure(address(this), 100, 100, 200);
        book.configure(PAYER, 50, 0, 200);
        book.shareCommission(PAYER);
        book.reCalFs(address(this));

        uint256 paid = book.claim(address(this));
        assertEq(book.fsOf(address(this)), 75, "fs refreshed to 0.75");
        assertEq(book.balanceOf(address(this)), 150, "balance");
        assertEq(paid, 150, "fair reward after refresh");
        console2.log("control fs hundredths", book.fsOf(address(this)));
        console2.log("control reward", paid);
    }
}
