// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./41383-c-02-native-tokens-in-the-daos-are-stuck-pashov-audit-group.sol";
contract Finding41383Test is Test {
    function test_native_deposit_stays_in_dao() public {
        Exploit e = new Exploit();
        vm.deal(address(e), 1 ether);
        e.run();
        assertEq(address(e.dao()).balance, 1 ether);
        assertEq(e.forwarded(), 0);
        assertEq(e.stillThere(), 1 ether);
    }
}
