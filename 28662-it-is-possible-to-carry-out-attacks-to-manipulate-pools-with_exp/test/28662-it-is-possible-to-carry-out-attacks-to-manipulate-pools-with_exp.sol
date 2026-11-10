// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./28662-it-is-possible-to-carry-out-attacks-to-manipulate-pools-with.sol";

contract Finding28662Test is Test {
    function test_flash_loan_spot_price_pays_attacker() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.spotPaid(), 320 ether, "manipulated spot pays 320");
        assertEq(e.router().quoteTwap(20 ether), 20 ether, "twap pays 20");
        assertEq(e.profit(), 299591836734693877552, "profit");
        assertEq(e.a().balanceOf(address(e)), e.profit(), "attacker balance");
        console2.log("spot paid wei", e.spotPaid());
        console2.log("profit wei", e.profit());
    }

    function test_control_twap_profit_disappears() public {
        Exploit e = new Exploit();
        e.runControl();
        // 1 ether of dust was minted so the loan could be repaid. The TWAP
        // round trip finishes below that dust: the 299 ether spot profit is gone.
        assertEq(e.a().balanceOf(address(e)), 591836734693877552, "left with less than the dust");
        assertEq(e.profit(), 0, "control records no profit");
        console2.log("control leftover wei", e.a().balanceOf(address(e)));
    }
}
