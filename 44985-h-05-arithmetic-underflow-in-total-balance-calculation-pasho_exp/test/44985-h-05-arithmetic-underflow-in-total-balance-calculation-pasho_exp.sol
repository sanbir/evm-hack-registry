// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, MockToken, DepositETH} from
    "./44985-h-05-arithmetic-underflow-in-total-balance-calculation-pasho.sol";

contract Finding44985Test is Test {
    function test_exploit_share_price_underflow_locks_30() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(address(e.dep())), 30 ether, "30 reward tokens locked");
        assertEq(e.dep().sharePrice(), 0, "share price was not written");
        assertEq(e.dep().ethWithdrawn(), 150 ether, "withdrawals already exceed deposits");
    }

    function test_control_reordered_sum_sets_share_price() public {
        MockToken token = new MockToken();
        DepositETH dep = new DepositETH(token);
        token.mint(address(dep), 30 ether);
        dep.updateFixed(80 ether);

        uint256 total = 100 ether + 80 ether - 150 ether;
        assertEq(total, 30 ether, "true balance");
        uint256 minted = 100 ether;
        uint256 base = 1e18;
        uint256 expectedPrice = minted * base / 30 ether;
        assertEq(dep.sharePrice(), expectedPrice, "share price uses the reordered sum");
        assertEq(dep.rewardsClaimed(), 80 ether, "rewards recorded");
    }
}
