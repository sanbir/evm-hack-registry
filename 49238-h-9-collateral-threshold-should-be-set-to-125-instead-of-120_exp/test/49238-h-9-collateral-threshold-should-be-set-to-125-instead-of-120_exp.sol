// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./49238-h-9-collateral-threshold-should-be-set-to-125-instead-of-120.sol";

contract Finding49238Test is Test {
    function test_leverage_loses_28_when_tvl_crosses_120() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.levBefore(), 238, "before");
        assertEq(e.levAfter(), 210, "after");
        assertEq(e.loss(), 28, "loss");
        assertEq(e.fairAfter(), 242, "fair");
    }
}
