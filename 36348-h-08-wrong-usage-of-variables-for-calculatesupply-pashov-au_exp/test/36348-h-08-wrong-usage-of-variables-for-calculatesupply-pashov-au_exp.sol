// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, AssetToken, LpToken, PoolFixed} from "./36348-h-08-wrong-usage-of-variables-for-calculatesupply-pashov-au.sol";

contract Finding36348Test is Test {
    function test_exploit_mints_the_pre_fee_supply() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.firstMint(), 0, "empty pool reverts the first add");
        assertEq(e.minted(), 200000000000000020218, "buggy mint");
        assertEq(e.fairMinted(), 179999999999999942197, "fair mint");
        assertEq(e.minted() - e.fairMinted(), 20000000000000078021, "20 LP excess");
        assertEq(e.quote0(), 100000000000000000054, "withdrawal ignores the fee");
    }

    function test_control_first_add_mints_and_the_fee_is_charged() public {
        AssetToken t0 = new AssetToken("T0");
        AssetToken t1 = new AssetToken("T1");
        LpToken lp = new LpToken();
        PoolFixed pool = new PoolFixed(lp);
        t0.mint(address(pool), 100 ether);
        t1.mint(address(pool), 100 ether);
        uint256 first = pool.addLiquidity(100 ether, 100 ether, address(this));
        assertGt(first, 0, "first deposit mints");
        assertEq(pool.supply(), first, "supply is the first mint");
        t0.mint(address(pool), 100 ether);
        t1.mint(address(pool), 100 ether);
        uint256 second = pool.addLiquidity(100 ether, 100 ether, address(this));
        assertLt(second, 200 ether, "the 10 percent fee is not minted to the depositor");
    }
}
