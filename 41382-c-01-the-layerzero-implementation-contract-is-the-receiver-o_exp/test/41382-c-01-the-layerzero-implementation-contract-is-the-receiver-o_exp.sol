// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./41382-c-01-the-layerzero-implementation-contract-is-the-receiver-o.sol";

contract Finding41382Test is Test {
    function test_exploit_owner_fee_stuck_on_the_factory() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 2 ether);
        e.run{value: 1 ether}();
        assertEq(e.ownerReceived(), 0, "dao owner received nothing");
        assertEq(address(e.factory()).balance, 0.1 ether, "0.1 ETH stuck");
        assertEq(address(e.daoOwner()).balance, 0, "owner balance");
        assertEq(address(e.treasury()).balance, 0.9 ether, "raise booked");
        assertEq(e.factory().ownerOf(e.dao()), address(e.lz()), "fee target is the deployer");
    }
}
