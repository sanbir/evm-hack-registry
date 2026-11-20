// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, SHTokenFixed} from "./52313-hal-06-anyone-can-burn-shtoken-from-other-users-halborn-supe.sol";

contract Finding52313Test is Test {
    address internal constant ALICE = 0x2222222222222222222222222222222222222222;
    address internal constant BOB = 0x3333333333333333333333333333333333333333;
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_bob_burns_alice() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(ALICE), 0, "alice at 0");
        assertEq(e.marker().balanceOf(SINK), 10 ether, "10 burned");
    }

    function test_control_only_owner_burns() public {
        SHTokenFixed token = new SHTokenFixed();
        token.mint(ALICE, 10 ether);
        vm.prank(BOB);
        vm.expectRevert(bytes("owner"));
        token.burn(ALICE, 10 ether);
        assertEq(token.balanceOf(ALICE), 10 ether, "alice keeps 10");
    }
}
