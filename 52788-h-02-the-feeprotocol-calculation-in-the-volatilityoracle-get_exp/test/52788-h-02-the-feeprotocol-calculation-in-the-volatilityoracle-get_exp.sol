// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Coll, Debt, VolatilityOracleFixed, Borrower} from
    "./52788-h-02-the-feeprotocol-calculation-in-the-volatilityoracle-get.sol";

contract Finding52788Test is Test {
    function test_exploit_buggy_iv_liquidates_healthy_borrower() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.oracle().gamma0(), 2750, "gamma0");
        assertEq(e.oracle().gamma1(), 3000, "gamma1");
        assertEq(e.oracle().fairGamma(), 1950, "fair");
        assertEq(e.oracle().iv(), 3348, "iv");
        assertEq(e.oracle().ivFair(), 2757, "iv fair");
        assertEq(e.coll().balanceOf(address(e)), 10 ether, "seized 10");
        assertEq(e.book().valueFair(), 20_000 ether, "fair 20000");
        assertLt(e.book().valueUsed(), 18_750 ether, "below 80 percent threshold");
        assertGt(e.book().valueFair(), 18_750 ether, "fair stays above threshold");
    }

    function test_control_basis_point_gamma_does_not_liquidate() public {
        VolatilityOracleFixed fixedOracle = new VolatilityOracleFixed();
        fixedOracle._getPoolMetadata();
        assertEq(fixedOracle.gamma0(), 1950, "gamma0");
        assertEq(fixedOracle.gamma1(), 1950, "gamma1");
        assertEq(uint256(fixedOracle.FEE_PROTOCOL() % 16), 12, "uniswap nibble");
        assertEq(uint256(fixedOracle.FEE_PROTOCOL() & 0xffff), 3500, "low half");
        assertEq(uint256(fixedOracle.FEE_PROTOCOL() >> 16), 3500, "high half");
    }
}
