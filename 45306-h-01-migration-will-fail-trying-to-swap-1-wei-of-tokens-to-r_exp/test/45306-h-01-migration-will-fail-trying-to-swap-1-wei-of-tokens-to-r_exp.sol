// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, MigToken, UniPool, MigratorFixed} from
    "./45306-h-01-migration-will-fail-trying-to-swap-1-wei-of-tokens-to-r.sol";

contract Finding45306Test is Test {
    function test_exploit_one_wei_swap_leaves_1000_tokens_unmigrated() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.migrator().adjustFailed(), "adjust failed");
        assertFalse(e.migrator().migrated(), "not migrated");
        assertEq(e.token().balanceOf(address(e.migrator())), 1000 ether, "1000 stuck");
        assertEq(e.pool().price(), 1001, "stopped at constrained tick");
        assertEq(e.token().balanceOf(address(e.pool())), 0, "pool received nothing");
    }

    function test_control_exact_swap_migrates_1000_tokens() public {
        MigToken token = new MigToken();
        UniPool pool = new UniPool(1000);
        MigratorFixed fixedMigrator = new MigratorFixed(token, pool);
        token.mint(address(this), 1000 ether);
        token.transfer(address(fixedMigrator), 1000 ether);
        fixedMigrator.migrate();

        assertFalse(fixedMigrator.adjustFailed(), "adjust ok");
        assertTrue(fixedMigrator.migrated(), "migrated");
        assertEq(pool.price(), 5000, "target price");
        assertEq(token.balanceOf(address(fixedMigrator)), 0, "migrator empty");
        assertEq(token.balanceOf(address(pool)), 1000 ether, "pool holds 1000");
    }
}
