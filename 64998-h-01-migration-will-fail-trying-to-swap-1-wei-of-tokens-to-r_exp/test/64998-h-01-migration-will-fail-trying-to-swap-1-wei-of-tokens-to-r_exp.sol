// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    MiniV3Pool,
    OldPool,
    IUniswapV3Pool
} from "./64998-h-01-migration-will-fail-trying-to-swap-1-wei-of-tokens-to-r.sol";

/// Control: swap the full distance to the target instead of 1 wei.
contract FixedMigrator {
    address public poolAddress;
    MiniToken public oldToken;
    MiniToken public newToken;
    address public oldPool;
    address public user;

    constructor(address pool, MiniToken _old, MiniToken _newT, address _oldPool, address _user) {
        poolAddress = pool;
        oldToken = _old;
        newToken = _newT;
        oldPool = _oldPool;
        user = _user;
    }

    function migrate() external {
        uint160 target = 1000;
        uint256 needed = uint256(target) - 100;
        IUniswapV3Pool(poolAddress).swap(address(this), false, int256(needed), target, "");
        (uint160 got,,,,,,) = IUniswapV3Pool(poolAddress).slot0();
        require(got == target, "target not reached");
        uint256 bal = oldToken.balanceOf(oldPool);
        oldToken.burn(oldPool, bal);
        newToken.mint(user, bal);
    }
}

contract Finding64998Test is Test {
    function test_exploit_migration_reverts_and_tokens_stay() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.oldToken().balanceOf(address(e.oldPool())), e.STUCK(), "stuck in old pool");
        assertEq(e.newToken().balanceOf(address(e)), 0, "no new tokens");
    }

    function test_control_exact_swap_migrates() public {
        MiniToken oldToken = new MiniToken("OLD", "OLD");
        MiniToken newToken = new MiniToken("NEW", "NEW");
        MiniV3Pool pool = new MiniV3Pool(100);
        OldPool oldPool = new OldPool();
        FixedMigrator fixedM = new FixedMigrator(address(pool), oldToken, newToken, address(oldPool), address(this));
        uint256 n = 1_000_000 ether;
        oldToken.mint(address(oldPool), n);
        fixedM.migrate();
        assertEq(oldToken.balanceOf(address(oldPool)), 0, "old pool emptied");
        assertEq(newToken.balanceOf(address(this)), n, "user received new tokens");
        assertEq(pool.sqrtPriceX96(), 1000, "target price");
    }
}
