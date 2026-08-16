// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import {Exploit, ValueFacet, Vertex, Closure, MiniToken} from "./56957-h-8-valuefacetremovevaluesingle-will-withdraw-less-than-requ.sol";
contract Finding56957Test is Test {
    function test_removeValueSingle_withdrawsLessByTax() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vaultReleased(), 990 ether, "vault released only removedBalance");
        assertEq(e.shortfall(), 10 ether, "short by realTax");
    }
}
