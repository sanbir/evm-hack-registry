// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Asset,
    Exploit,
    FeeTooSmall,
    MasterFixed,
    UserVault
} from "./62252-insufficient-fee-validation-leading-to-user-contract-state-l.sol";

contract Finding62252Test is Test {
    function test_exploit_short_fee_locks_withdraw() public {
        Exploit e = new Exploit();
        e.run{value: 0.51 ether}();
        assertEq(e.user().state(), 1, "state");
        assertFalse(e.withdrew(), "withdraw flag");
        assertEq(e.token().balanceOf(address(e.user())), 100 ether, "stuck");
        assertEq(e.token().balanceOf(e.owner()), 0, "owner");
        emit log_named_uint("stuck", e.token().balanceOf(address(e.user())));
    }

    function test_control_rejects_fee_and_withdraw_pays() public {
        Asset token = new Asset();
        address owner = address(0xA11CE);
        UserVault user = new UserVault(token, owner);
        MasterFixed master = new MasterFixed(user);
        token.mint(address(user), 100 ether);

        vm.expectRevert(FeeTooSmall.selector);
        master.liquidate{value: 0.51 ether}();
        assertEq(user.state(), 0, "still free");

        user.withdraw(100 ether);
        assertEq(token.balanceOf(owner), 100 ether, "paid N");
        assertEq(token.balanceOf(address(user)), 0, "vault empty");
    }
}
