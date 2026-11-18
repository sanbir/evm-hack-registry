// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit} from "./53114-first-deposits-will-be-ignored-and-lost-cantina-none-beracha.sol";
contract Finding53114Test is Test {
    function test_exploit_first_deposit_overwrites_genesis() public {
        Exploit e = new Exploit();
        e.run();
        (bytes32 pubkey, uint256 amount, bool exists) = e.store().deposits(0);
        assertTrue(exists);
        assertEq(pubkey, e.NEWKEY());
        assertEq(amount, 1 ether);
        assertEq(e.vault().depositCount(), 1);
        assertEq(e.ethToken().balanceOf(address(e.vault())), 1 ether);
    }
}
