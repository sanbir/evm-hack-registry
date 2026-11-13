// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    USDC,
    PreMarkets,
    DeliveryPlaceFixed
} from "./38089-missing-abort-status-check-allows-bid-taker-to-steal-users-f.sol";

contract Finding38089Test is Test {
    function test_exploit_aborted_offer_pays_the_collateral_premium() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.received(), 0.006 ether, "taker credited 0.006");
        assertEq(e.received() - 0.005 ether, 0.001 ether, "0.001 stolen");
        assertEq(e.poolLeft(), 1 ether + 0.004 ether, "pool retains 1.004");
        assertEq((1 ether + 0.005 ether) - e.poolLeft(), 0.001 ether, "short of the fair residual");
        assertEq(e.usdc().balanceOf(address(e.maker())), 0.007 ether, "maker refund");
    }

    function test_control_abort_check_blocks_the_premium() public {
        USDC usdc = new USDC();
        PreMarkets pre = new PreMarkets();
        pre.seed(address(this), address(usdc));
        DeliveryPlaceFixed delivery = new DeliveryPlaceFixed(usdc, pre);
        usdc.mint(address(delivery), 1 ether + 0.012 ether + 0.005 ether);
        delivery.fund(1 ether + 0.012 ether + 0.005 ether);
        pre.abortAskOffer();
        vm.expectRevert(bytes("Pre offer aborted"));
        delivery.closeBidTaker();
        delivery.payDeposit(address(this));
        assertEq(usdc.balanceOf(address(this)), 0.005 ether, "deposit only");
        assertEq(delivery.pool(), 1 ether + 0.012 ether, "premium stays in the pool");
    }
}
