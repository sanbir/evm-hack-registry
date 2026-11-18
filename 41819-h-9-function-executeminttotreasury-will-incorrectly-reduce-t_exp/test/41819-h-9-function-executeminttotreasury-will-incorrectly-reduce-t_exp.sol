// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, Sink, PoolLogic} from
    "./41819-h-9-function-executeminttotreasury-will-incorrectly-reduce-t.sol";

contract Finding41819Test is Test {
    function test_exploit_last_withdrawer_is_locked() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.bobReverted(), "bob withdraw reverts");
        assertEq(e.bobSharesLeft(), 100, "bob still holds 100 shares");
        assertEq(e.lockedUnderlying(), 100, "100 underlying stuck in the pool");
        assertEq(e.asset().balanceOf(address(e.alice())), 100, "alice was paid");
        assertEq(e.asset().balanceOf(address(e.treasury())), 50, "treasury received the premium");
        assertEq(e.pool().supplyShares(), 50, "supplyShares is 50 against 100 of bob shares");
    }

    function test_control_fix_lets_bob_withdraw() public {
        Asset asset = new Asset();
        Sink alice = new Sink();
        Sink treasury = new Sink();
        PoolLogic pool = new PoolLogic(asset, true);
        asset.mint(address(this), 250);
        asset.approve(address(pool), 250);
        pool.seed(address(alice), address(this), 100, 100, 50, 250);

        pool.executeMintToTreasury(address(treasury));
        assertEq(pool.supplyShares(), 200, "shares untouched");
        pool.withdraw(address(alice), 100);
        pool.withdraw(address(this), 100);
        assertEq(asset.balanceOf(address(this)), 100, "bob received 100");
        assertEq(asset.balanceOf(address(pool)), 0, "pool empty");
    }
}
