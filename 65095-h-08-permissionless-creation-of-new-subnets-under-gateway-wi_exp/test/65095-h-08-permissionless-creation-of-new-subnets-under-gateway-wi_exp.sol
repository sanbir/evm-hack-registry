// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, GatewayFixed} from
    "./65095-h-08-permissionless-creation-of-new-subnets-under-gateway-wi.sol";

contract Finding65095Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_books_2000_after_paying_1000() public {
        vm.deal(address(this), 1000 ether);
        Exploit e = new Exploit();
        e.run{value: 1000 ether}();
        assertEq(e.gateway().circSupply(), 1000 ether, "supply");
        assertEq(e.gateway().stake(), 1000 ether, "stake");
        assertEq(e.gateway().received(), 1000 ether, "cash");
        assertEq(e.marker().balanceOf(SINK), 1000 ether, "short 1000");
    }

    function test_control_requires_the_sum() public {
        vm.deal(address(this), 3000 ether);
        GatewayFixed gateway = new GatewayFixed();
        vm.expectRevert(bytes("sum"));
        gateway.register{value: 1000 ether}(1000 ether, 1000 ether);
        gateway.register{value: 2000 ether}(1000 ether, 1000 ether);
        assertEq(gateway.received(), 2000 ether, "both locks paid");
        assertEq(gateway.circSupply() + gateway.stake(), gateway.received(), "books the cash");
    }
}
