// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Asset, PoolV3Fixed, CDPVaultFixed, Treasury} from
    "./49112-h-02-cdpvaultsolliquidatepositionbaddebt-doesnt-correctly-ha.sol";

contract Finding49112Test is Test {
    function test_exploit_treasury_burned_60_and_lp_overpaid() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.treasuryShares(), 40 ether, "60 burned");
        assertEq(e.payout(), 957446808510638297872, "lp payout");
        assertEq(e.asset().balanceOf(address(e)), 957446808510638297872, "lp balance");
    }

    function test_control_burning_10_pays_the_lp_909() public {
        Asset asset = new Asset();
        Asset collateral = new Asset();
        Treasury treasury = new Treasury();
        PoolV3Fixed pool = new PoolV3Fixed(asset, address(treasury));
        CDPVaultFixed vault = new CDPVaultFixed(pool, collateral);
        pool.seed(address(this), 900 ether, 100 ether, 1000 ether);
        vault.liquidatePositionBadDebt();
        assertEq(pool.balanceOf(address(treasury)), 90 ether, "burned 10");
        uint256 payout = pool.redeem(900 ether);
        assertEq(payout, 909090909090909090909, "fair");
        assertEq(asset.balanceOf(address(this)), 909090909090909090909, "lp");
    }
}
