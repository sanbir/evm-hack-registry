// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, CrvUsd, Collateral, LendingPool, StabilityPool} from
    "./57192-double-usage-index-scaling-in-stabilitypool-liquidation-infl.sol";

contract Finding57192Test is Test {
    function test_exploit_double_scale_blocks_liquidation() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.liquidateReverted(), "reverted");
        assertFalse(e.pool().seized(), "not seized");
        assertEq(e.collateral().ownerOf(1), e.borrower(), "borrower keeps nft");
        assertEq(e.crv().balanceOf(address(e.pool())), 80_000 ether, "pool untouched");
        assertLt(e.actualDebt(), 80_000 ether, "80k covers actual debt");
        assertGt(e.doubleScaled(), 80_000 ether, "80k does not cover double scale");
    }

    function test_control_single_scale_seizes_collateral() public {
        address borrower = address(0xB0B);
        CrvUsd crv = new CrvUsd();
        Collateral collateral = new Collateral();
        LendingPool lending = new LendingPool();
        StabilityPool pool = new StabilityPool(crv, lending, collateral);
        lending.setNormalizedDebt(1410226029899202994928355252);
        lending.setPrincipal(borrower, 50_000 ether);
        collateral.mint(borrower, 1);
        crv.mint(address(pool), 80_000 ether);

        pool.liquidateBorrowerFixed(borrower);

        assertTrue(pool.seized(), "seized");
        assertEq(collateral.ownerOf(1), address(pool), "pool holds nft");
        assertLt(lending.getUserDebt(borrower), crv.balanceOf(address(pool)), "balance covered debt");
    }
}
