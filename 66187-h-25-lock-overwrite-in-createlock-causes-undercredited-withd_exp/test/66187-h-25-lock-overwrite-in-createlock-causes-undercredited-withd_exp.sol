// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, VeRAACToken, MockToken} from "./66187-h-25-lock-overwrite-in-createlock-causes-undercredited-withd.sol";

contract Finding66187Test is Test {
    function test_second_lock_overwrites_and_withdraw_underpays() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stuck(), 1000 ether, "stuck");
        assertEq(e.returnedAmount(), 1000 ether, "returned");
        assertEq(e.ve().FINDING(), "66187");
    }

    function test_control_second_lock_reverts() public {
        MockToken raac = new MockToken();
        VeRAACToken ve = new VeRAACToken(raac, true);
        raac.mint(address(this), 2000 ether);
        raac.approve(address(ve), 2000 ether);
        ve.lock(1000 ether, 0);
        vm.expectRevert(bytes("LockFound"));
        ve.lock(1000 ether, 0);
        assertEq(raac.balanceOf(address(ve)), 1000 ether, "only one debit");
    }
}
