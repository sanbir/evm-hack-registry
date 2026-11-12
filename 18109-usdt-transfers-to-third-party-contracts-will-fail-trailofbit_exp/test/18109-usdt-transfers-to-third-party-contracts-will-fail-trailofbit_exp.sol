// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    UsdtLike,
    ReturningToken
} from "./18109-usdt-transfers-to-third-party-contracts-will-fail-trailofbit.sol";

contract Finding18109Test is Test {
    function test_usdt_release_sticks_and_control_pays() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.parked(), e.N(), "parked");
        assertFalse(e.usdtReleased(), "usdt release returned");
        assertEq(e.stuck(), e.N(), "stuck");
        assertEq(e.usdtPaid(), 0, "usdt paid");
        assertEq(e.allowanceLeft(), 0, "allowance");
        assertEq(e.controlReceived(), e.N(), "control");
        assertEq(e.standardLeft(), 0, "standard left");

        UsdtLike usdt = e.usdt();
        ReturningToken standard = e.standard();
        assertEq(usdt.balanceOf(address(e.pool())), e.N(), "pool usdt");
        assertEq(usdt.balanceOf(e.BENEFICIARY()), 0, "beneficiary usdt");
        assertEq(standard.balanceOf(e.BENEFICIARY()), e.N(), "beneficiary standard");
        assertEq(standard.balanceOf(address(e.pool())), 0, "pool standard");

        console2.log("parked USDT");
        console2.log(e.parked());
        console2.log("usdt release returned");
        console2.log(e.usdtReleased() ? 1 : 0);
        console2.log("USDT stuck in pool");
        console2.log(e.stuck());
        console2.log("USDT paid to beneficiary");
        console2.log(e.usdtPaid());
        console2.log("allowance left");
        console2.log(e.allowanceLeft());
        console2.log("control received");
        console2.log(e.controlReceived());
        console2.log("standard left in pool");
        console2.log(e.standardLeft());
    }
}
