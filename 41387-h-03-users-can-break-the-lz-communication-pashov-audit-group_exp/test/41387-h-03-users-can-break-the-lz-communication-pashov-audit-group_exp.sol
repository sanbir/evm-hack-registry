// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Endpoint, LayerZeroImpl, DaoToken, Bob} from
    "./41387-h-03-users-can-break-the-lz-communication-pashov-audit-group.sol";

contract Finding41387Test is Test {
    function test_exploit_gas_burn_blocks_pathway() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.endpoint().blocked(), "blocked");
        assertEq(e.lz().failedStored(), 0, "ua store");
        assertEq(e.dao().balanceOf(address(e.bob())), 0, "bob mint");
        assertTrue(e.legitBlocked(), "legit blocked");
        assertEq(e.legitBalance(), 0, "legit balance");
        assertEq(e.endpoint().delivered(), 0, "delivered");
    }

    function test_control_eoa_buyer_does_not_block() public {
        DaoToken dao = new DaoToken();
        LayerZeroImpl lz = new LayerZeroImpl(dao);
        Endpoint endpoint = new Endpoint(lz);
        address eoa = address(0xB0B);

        endpoint.deliver(eoa);

        assertFalse(endpoint.blocked(), "not blocked");
        assertEq(endpoint.delivered(), 1, "delivered");
        assertEq(dao.balanceOf(eoa), 1, "minted");
        assertEq(lz.failedStored(), 0, "no failure");
    }
}
