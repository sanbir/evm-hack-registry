// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Debt,
    Exploit,
    OmoOracleFixed,
    Pool,
    PositionManager
} from "./53326-h-08-omooracle-getliquidityamounts-uses-spot-price-making-it.sol";

contract Finding53326Test is Test {
    function test_exploit_spot_price_mints_extra_debt() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.minted(), 2000, "spot value");
        assertEq(e.extra(), 1000, "extra over the fair 1000");
        assertEq(e.debt().balanceOf(address(this)), 1000, "extra paid to caller");
        assertEq(e.debt().balanceOf(address(e)), 1000, "fair portion stayed");
    }

    function test_control_fixed_price_ignores_the_swap() public {
        Debt debt = new Debt();
        Pool pool = new Pool();
        PositionManager pm = new PositionManager(address(pool));
        OmoOracleFixed oracle = new OmoOracleFixed();
        pool.moveSpot(uint160(uint256(1 << 96) * 2));

        uint256 value = oracle.getPositionValue(address(pm), 1, 1000);
        assertEq(value, 1000, "fixed price stays at the fair value");
        debt.mint(address(this), value);
        assertEq(debt.balanceOf(address(this)), 1000, "control mints 1000, not 2000");
    }
}
