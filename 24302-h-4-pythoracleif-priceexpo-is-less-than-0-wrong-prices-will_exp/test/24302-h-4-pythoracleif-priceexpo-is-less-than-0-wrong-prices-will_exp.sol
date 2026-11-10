// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    CollateralToken,
    Exploit,
    LendingPool,
    PythOracleFixed,
    PythStructs,
    UsdToken
} from "./24302-h-4-pythoracleif-priceexpo-is-less-than-0-wrong-prices-will.sol";

contract Finding24302Test is Test {
    function test_exploit_negative_expo_borrows_400k() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.buggyPrice(), 500_000e6, "recorded 5e5, not 5e-5");
        assertEq(e.fairPrice(), 50, "fair Fixed6 raw is 5e-5");
        assertEq(e.buggyPrice() / e.fairPrice(), 10_000_000_000, "10^10 too high");
        assertEq(e.borrowed(), 400_000e6, "400,000 USDC borrowed");
        assertEq(e.usd().balanceOf(address(0x1111111111111111111111111111111111111111)), 400_000e6, "attacker received USDC");
    }

    function test_control_correct_exponent_rejects_the_borrow() public {
        CollateralToken coll = new CollateralToken();
        UsdToken usd = new UsdToken();
        PythOracleFixed oracle = new PythOracleFixed();
        LendingPool pool = new LendingPool(coll, usd, oracle);

        coll.mint(address(this), 1e18);
        usd.mint(address(pool), 400_000e6);
        coll.approve(address(pool), 1e18);

        oracle.commit(PythStructs.Price({price: 5, conf: 0, expo: -5, publishTime: 1}));
        assertEq(oracle.recorded(1), 50, "fixed oracle stores 5e-5");

        vm.expectRevert(bytes("ltv"));
        pool.depositAndBorrow(1e18, 400_000e6);

        // The same 1 token can borrow only the fair maximum: 40 base units.
        pool.depositAndBorrow(1e18, 40);
        assertEq(pool.lastMaxBorrow(), 40, "fair max borrow");
        assertEq(usd.balanceOf(address(this)), 40, "only dust USDC moves");
    }
}
