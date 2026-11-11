// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Usd, MarketFixed, Precision} from
    "./18640-h-14-pool-value-calculation-uses-wrong-portion-of-the-borrow.sol";

contract Finding18640Test is Test {
    function test_exploit_withdrawal_uses_receiver_slice() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.market().poolValue(), 10_300e18, "pool value includes 300 receiver slice");
        assertEq(e.market().fairPoolValue(), 10_700e18, "fair value includes 700 pool slice");
        assertEq(e.token().balanceOf(address(this)), 10_300e18, "LP withdrawn 10300");
        assertEq(e.market().fairPoolValue() - e.market().paid(), 400e18, "short 400");
        assertEq(Precision.applyFactor(1_000e18, 3 * 10 ** 29), 300e18, "30 percent");
    }

    function test_control_uses_pool_portion() public {
        Usd token = new Usd();
        MarketFixed fixedMarket = new MarketFixed(token);
        fixedMarket.seed(address(this));
        assertEq(fixedMarket.getPoolValue(), 10_700e18, "control value");

        fixedMarket.withdraw(address(this));
        assertEq(fixedMarket.paid(), 10_700e18, "control pays 10700");
        assertEq(fixedMarket.fairPoolValue(), 10_700e18, "fair matches");
        assertEq(token.balanceOf(address(this)), 10_700e18, "LP receives the pool slice");
        assertEq(token.balanceOf(address(fixedMarket)), 300e18, "only the receiver's 300 remains");
    }
}
