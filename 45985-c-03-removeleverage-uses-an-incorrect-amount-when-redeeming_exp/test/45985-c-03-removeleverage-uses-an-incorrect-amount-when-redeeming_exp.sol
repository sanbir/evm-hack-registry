// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, LendingPair, Dex, LeverageManagerFixed} from
    "./45985-c-03-removeleverage-uses-an-incorrect-amount-when-redeeming.sol";

contract Finding45985Test is Test {
    function test_exploit_redeem_uses_leftover_pods_and_leaves_debt() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stuckShares(), 980 ether, "shares");
        assertEq(e.borrowGot(), 10 ether, "borrow");
        assertEq(e.debtLeft(), 990 ether, "debt");
        assertEq(e.borrowToken().balanceOf(address(e)), 0, "user");
    }

    function test_control_redeems_share_balance_and_clears_debt() public {
        Token pod = new Token("POD");
        Token borrowToken = new Token("BORROW");
        LendingPair pair = new LendingPair(borrowToken);
        Dex dex = new Dex(pair);
        LeverageManagerFixed mgr = new LeverageManagerFixed(pod, borrowToken, pair, dex);
        borrowToken.mint(address(pair), 1000 ether);
        pod.mint(address(this), 1000 ether);
        pod.approve(address(mgr), 1000 ether);
        uint256 left = mgr.removeLeverage(1000 ether, 990 ether);
        assertEq(left, 0, "debt");
        assertEq(borrowToken.balanceOf(address(this)), 990 ether, "repaid");
        assertEq(pair.balanceOf(address(mgr)), 0, "shares");
    }
}
