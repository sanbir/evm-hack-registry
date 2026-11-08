// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    SGLP,
    GmxRewards,
    GlpStrategy,
    YieldBox
} from "./31527-c-02-attackers-can-steal-unclaimed-rewards-from-glpstrategy.sol";

/// Recommended fix: count GMX-claimable rewards in the share-price balance.
contract GlpStrategyFixed is GlpStrategy {
    constructor(address _sglp, address _gmx) GlpStrategy(_sglp, _gmx) {}

    function _currentBalance() internal view override returns (uint256 amount) {
        amount = sglp.balanceOf(address(this));
        amount += pendingRewards();
        amount += gmx.claimable(address(this));
    }
}

contract Finding31527Test is Test {
    function test_exploit_deposit_mints_against_undercounted_rewards() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.sharesOut(), e.DEPOSIT(), "attacker minted 1:1 against the stale balance");
        assertEq(e.withdrawn(), e.DEPOSIT() + e.STOLEN(), "attacker withdrew 9,450 sGLP");
        assertEq(e.sglp().balanceOf(address(e)), 9450e18, "attacker holds the stolen 450");
        assertEq(e.yieldBox().preview(e.VICTIM()), 1050e18, "victim can redeem only 1,050 of 1,500");
        assertEq(e.STOLEN(), 450e18, "stolen amount");
    }

    function test_control_counting_gmx_claimable_pays_the_victim() public {
        SGLP sglp = new SGLP();
        GmxRewards gmx = new GmxRewards();
        GlpStrategyFixed strategy = new GlpStrategyFixed(address(sglp), address(gmx));
        YieldBox yieldBox = new YieldBox(address(sglp), address(strategy));
        sglp.mint(address(strategy), 1000e18);
        yieldBox.seed(address(0xBEEF), 1000e18);
        gmx.setClaimable(address(strategy), 500e18);
        sglp.mint(address(this), 9000e18);
        sglp.approve(address(yieldBox), type(uint256).max);

        uint256 share = yieldBox.deposit(9000e18);
        assertEq(share, 6000e18, "shares match the balance that includes the 500");
        uint256 out = yieldBox.withdraw(share);
        assertEq(out, 9000e18, "attacker receives only the deposit");
        assertEq(sglp.balanceOf(address(this)), 9000e18, "no profit");
        assertEq(yieldBox.preview(address(0xBEEF)), 1500e18, "victim keeps principal plus rewards");
    }
}
