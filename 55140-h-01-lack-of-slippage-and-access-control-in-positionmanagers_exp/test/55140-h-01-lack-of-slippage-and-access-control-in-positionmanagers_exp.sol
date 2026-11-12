// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    FeeToken,
    PositionManager,
    Router,
    Volt
} from "./55140-h-01-lack-of-slippage-and-access-control-in-positionmanagers.sol";

contract Finding55140Test is Test {
    function test_exploit_open_collect_with_zero_min_takes_4() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), 4 ether, "4 taken");
        assertEq(e.fee().balanceOf(address(this)), 4 ether, "caller holds 4");
        assertEq(e.left(), 0, "manager empty");
    }

    function test_control_minOut_keeps_the_4() public {
        FeeToken fee = new FeeToken();
        Volt volt = new Volt();
        Router router = new Router();
        PositionManager manager = new PositionManager(fee, volt, router);
        fee.mint(address(manager), 4 ether);
        vm.expectRevert(bytes("min"));
        manager.collectFixed(4 ether);
        assertEq(fee.balanceOf(address(manager)), 4 ether, "4 stayed");
        assertEq(fee.balanceOf(address(this)), 0, "caller got nothing");
    }
}
