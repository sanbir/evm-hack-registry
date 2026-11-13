// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    BalancedVaultFixed
} from "./19152-h-1-balancedvaultsol-loss-of-funds-global-settlement-flywhee.sol";

contract Finding19152Test is Test {
    function test_pushed_epoch_shorts_the_user_50e18_shares() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.supplyAfter(), 100.5 ether, "global flywheel minted 100.5e18");
        assertEq(e.sharesAfter(), 50.5 ether, "user flywheel minted 50.5e18");
        assertEq(e.loss(), 50 ether, "gap is 50e18 shares");
    }

    function test_control_keeps_the_epoch_and_mints_fair_shares() public {
        BalancedVaultFixed vault = new BalancedVaultFixed();
        address user = address(this);

        vault.markStale();
        vault.deposit(100 ether, user);
        assertEq(vault._pendingEpochs(user), 2, "first pending epoch is 2");
        vault.settleGlobal();

        vault.markStale();
        vault.deposit(1 ether, user);
        assertEq(vault._pendingEpochs(user), 2, "second deposit does not push the epoch");

        vault.settleGlobal();
        vault.settleAccount(user);
        assertEq(vault._balanceOf(user), 101 ether, "user is minted at the epoch-3 price");

        vault.settleGlobal();
        vault.settleAccount(user);
        assertEq(vault._balanceOf(user), 101 ether, "epoch 4 does not reprice the deposit");
        assertEq(vault._totalSupply(), 100.5 ether, "global side is unchanged");
        assertGt(vault._balanceOf(user), vault._totalSupply() - 50 ether, "user is not short 50e18");
    }
}
