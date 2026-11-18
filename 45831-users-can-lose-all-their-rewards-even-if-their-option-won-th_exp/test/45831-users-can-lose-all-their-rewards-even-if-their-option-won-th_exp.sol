// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, USDC, Duel, Bettor} from "./45831-users-can-lose-all-their-rewards-even-if-their-option-won-th.sol";

contract Finding45831Test is Test {
    function test_exploit_winner_share_is_zero() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.duel().lastShareA(), 0, "alice share");
        assertEq(e.duel().lastShareB(), 1e18, "bob share");
        assertEq(e.usdc().balanceOf(address(e.alice())), 0, "alice unpaid");
        assertEq(e.usdc().balanceOf(address(e)), 2000 ether, "bob pot");
    }

    function test_control_reuse_token_splits_the_pot() public {
        USDC usdc = new USDC();
        Duel duel = new Duel(usdc);
        Bettor alice = new Bettor(usdc, duel);
        Bettor bob = new Bettor(usdc, duel);
        usdc.mint(address(alice), 1000 ether);
        usdc.mint(address(bob), 1000 ether);
        alice.approve();
        bob.approve();
        alice.join(1000 ether);
        bob.joinFixed(1000 ether);
        duel.distribute(address(alice), address(bob));
        assertEq(duel.lastShareA(), 5e17, "alice half");
        assertEq(duel.lastShareB(), 5e17, "bob half");
        assertEq(usdc.balanceOf(address(alice)), 1000 ether, "alice repaid");
        assertEq(usdc.balanceOf(address(bob)), 1000 ether, "bob repaid");
    }
}
