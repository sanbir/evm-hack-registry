// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import {Exploit, SwapImpl, WETH9, MaliciousPermit2} from "./63937-c-01-anyone-can-re-initialize-the-swapproxy-pashov-audit-gro.sol";
contract Finding63937Test is Test {
    function test_reinitSwapProxy_drainsWeth() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.drained(), 100 ether, "drained proxy WETH");
    }
}
