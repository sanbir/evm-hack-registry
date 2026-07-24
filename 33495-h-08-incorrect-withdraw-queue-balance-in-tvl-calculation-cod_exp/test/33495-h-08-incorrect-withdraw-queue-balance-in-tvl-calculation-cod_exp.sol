// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./33495-h-08-incorrect-withdraw-queue-balance-in-tvl-calculation-cod.sol";

contract RenzoWrongIndexTvlTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertLt(e.buggyTvl(), e.correctTvl(), "TVL must be understated");
        assertGe(e.correctTvl() - e.buggyTvl(), 100e18, "WQ mispricing gap");
        assertGt(e.sharesMinted(), 0, "shares minted");
        assertGt(e.manager().balanceOf(address(e)), 1e18, "attacker holds excess shares");
    }

    function test_buggy_lookup_uses_token0_price_three_times() public {
        RenzoOracle oracle = new RenzoOracle();
        MockERC20 t0 = new MockERC20();
        MockERC20 t1 = new MockERC20();
        MockERC20 t2 = new MockERC20();
        address wq = address(0xBEEF);
        RestakeManager m = new RestakeManager(wq, oracle);
        m.addCollateral(t0);
        m.addCollateral(t1);
        m.addCollateral(t2);
        oracle.setPrice(address(t0), 1e18);
        oracle.setPrice(address(t1), 10e18);
        oracle.setPrice(address(t2), 100e18);
        t0.mint(wq, 1e18);
        t1.mint(wq, 1e18);
        t2.mint(wq, 1e18);

        // Only WQ contributes (OD empty)
        assertEq(m.calculateTVLs(), 3e18, "buggy: 3x token0 price");
        assertEq(m.calculateTVLsCorrect(), 111e18, "correct: 1+10+100");
    }
}
