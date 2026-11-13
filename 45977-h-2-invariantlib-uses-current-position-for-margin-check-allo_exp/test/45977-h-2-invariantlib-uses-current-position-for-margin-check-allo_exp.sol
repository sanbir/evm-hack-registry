// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, DSU, MarketFixed, Actor} from
    "./45977-h-2-invariantlib-uses-current-position-for-margin-check-allo.sol";

contract Finding45977Test is Test {
    function test_exploit_pending_reduce_pays_liquidator_15() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.reward(), 15 ether, "reward");
        assertEq(e.dsu().balanceOf(address(e)), 15 ether, "liquidator");
        assertEq(e.collateralAfter(), 75 ether, "user left 75");
        assertTrue(e.healthyOnPending(), "pending was healthy");
    }

    function test_control_latest_size_reverts_the_withdrawal() public {
        DSU dsu = new DSU();
        MarketFixed market = new MarketFixed(dsu);
        Actor user = new Actor();
        dsu.mint(address(user), 200 ether);
        user.approve(dsu, address(market), 200 ether);
        user.call(address(market), abi.encodeWithSignature("openSettled(uint256,uint256)", 10 ether, 200 ether));
        vm.expectRevert(bytes("actor"));
        user.call(address(market), abi.encodeWithSignature("update(uint256,int256)", 5 ether, -int256(95 ether)));
        assertEq(dsu.balanceOf(address(market)), 200 ether, "still deposited");
        assertEq(market.collateralOf(address(user)), 200 ether, "collateral intact");
        assertEq(market.latest(address(user)), 10 ether, "size intact");
    }
}
