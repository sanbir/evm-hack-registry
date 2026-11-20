// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, LoaderFixed} from "./56732-inner-variable-shadowing-causes-incorrect-return-in-mloadpot.sol";

contract Finding56732Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_returns_the_unmasked_word() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.loader().returned(), 0xFFFFFFFF, "full word");
        assertEq(e.loader().masked(), 0xFFFFFF00, "mask computed");
        assertEq(e.marker().balanceOf(SINK), 0xFF, "low byte leaked");
    }

    function test_control_returns_the_masked_word() public {
        assertEq(new LoaderFixed().load(0xFFFFFFFF, 8), 0xFFFFFF00, "low byte cleared");
    }
}
