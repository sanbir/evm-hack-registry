// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, RaacToken, LockManager, VeRAACToken} from
    "./57158-users-can-overwrite-existing-locks-in-veraactoken-resulting.sol";

contract Finding57158Test is Test {
    function test_exploit_second_lock_strands_500_raac() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e.ve())), 500 ether, "500 stuck");
        assertEq(e.token().balanceOf(address(e)), 500 ether, "user left with 500");
        assertEq(e.stranded(), 500 ether, "stranded");
        assertEq(e.recovered(), 200 ether, "only second lock returned");
        (uint256 amount,, bool exists) = e.manager().locks(address(e));
        assertEq(amount, 0, "record cleared");
        assertFalse(exists, "no lock");
        assertEq(e.manager().totalLocked(), 500 ether, "orphan total");
    }

    function test_control_increase_withdraws_700_raac() public {
        RaacToken token = new RaacToken();
        LockManager manager = new LockManager();
        VeRAACToken ve = new VeRAACToken(token, manager);
        token.mint(address(this), 1000 ether);
        token.approve(address(ve), type(uint256).max);

        ve.lock(500 ether, 0);
        ve.increase(200 ether);
        (uint256 recorded,,) = manager.locks(address(this));
        assertEq(recorded, 700 ether, "increase keeps both");
        ve.withdraw();

        assertEq(token.balanceOf(address(this)), 1000 ether, "full withdraw");
        assertEq(token.balanceOf(address(ve)), 0, "ve empty");
        assertEq(manager.totalLocked(), 0, "nothing orphaned");
    }
}
