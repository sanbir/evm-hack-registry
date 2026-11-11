// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Dai,
    Middleware,
    VaultManager,
    RewardsBase,
    RewardsFixed
} from "./61237-vault-rewards-incorrectly-scaled-by-cross-asset-class-operat.sol";

contract Finding61237Test is Test {
    function test_exploit_cross_asset_scale() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.rewards().operatorBeneficiariesShares(1, e.rewards().operatorB()), 8500, "8500 bp cross-asset");
        assertEq(e.rewards().vaultShares(1, e.rewards().vault2()), 1700, "vault2 paid share 1700 bp");
        assertEq(e.rewards().vaultShares(1, e.rewards().vault3()), 2550, "vault3 paid share 2550 bp");
        assertEq(e.rewards().paid(), 17_000e18, "vault2 paid 17000");
        assertEq(e.rewards().fairPaid(), 20_000e18, "vault2 fair 20000");
        assertEq(e.token().balanceOf(e.rewards().staker()), 17_000e18, "staker received 17000");
        assertEq(e.token().balanceOf(e.rewards().reclaimer()), 3_000e18, "3000 reclaimed");
    }

    function test_control_uses_asset_class_share() public {
        Dai token = new Dai();
        Middleware middleware = new Middleware();
        VaultManager vaultManager = new VaultManager();
        RewardsFixed fixedRewards = new RewardsFixed(token, middleware, vaultManager);

        middleware.setAssetClasses(1, 2, 3);
        fixedRewards.setRewardsShareForAssetClass(1, 5000);
        fixedRewards.setRewardsShareForAssetClass(2, 2000);
        fixedRewards.setRewardsShareForAssetClass(3, 3000);
        middleware.setTotalStake(1, 1, 1000);
        middleware.setTotalStake(1, 2, 100);
        middleware.setTotalStake(1, 3, 100);
        middleware.setOperatorStake(1, fixedRewards.operatorB(), 1, 700);
        middleware.setOperatorStake(1, fixedRewards.operatorB(), 2, 100);
        middleware.setOperatorStake(1, fixedRewards.operatorB(), 3, 100);
        vaultManager.setVaultAssetClass(fixedRewards.vault2(), 2);
        vaultManager.setVaultAssetClass(fixedRewards.vault3(), 3);
        fixedRewards.setVaultStake(fixedRewards.vault2(), 100);
        fixedRewards.setVaultStake(fixedRewards.vault3(), 100);
        token.mint(address(fixedRewards), fixedRewards.EPOCH_REWARDS());

        fixedRewards.distribute(1, fixedRewards.operatorB());

        assertEq(fixedRewards.vaultShares(1, fixedRewards.vault2()), 2000, "class share 2000 bp");
        assertEq(fixedRewards.vaultShares(1, fixedRewards.vault3()), 3000, "class share 3000 bp");
        assertEq(fixedRewards.paid(), 20_000e18, "control pays the fair 20000");
        assertEq(fixedRewards.fairPaid(), 20_000e18, "fair");
        assertEq(fixedRewards.undistributed(), 0, "nothing reclaimed");
        assertEq(token.balanceOf(fixedRewards.staker()), 20_000e18, "staker receives 20000");
        assertEq(token.balanceOf(fixedRewards.reclaimer()), 0, "reclaimer empty");
    }
}
