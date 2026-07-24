// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20225-h-02-hedging-during-liquidation-is-incorrect-code4rena-polyn.sol";

/*//////////////////////////////////////////////////////////////
    Polynomial -- hedging during liquidation over-hedges pool (H-02, #20225)
//////////////////////////////////////////////////////////////////////////*/
contract PolynomialLiquidationHedgeTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        uint256 feeBefore = e.feeToken().balanceOf(address(e.pool()));
        e.run();
        assertEq(e.pool().hedgePosition(), int256(e.DEBT_REPAYING()), "over-hedged by debtRepaying");
        assertEq(e.feeToken().balanceOf(address(e.pool())), feeBefore - e.pool().HEDGE_FEE(), "pool paid hedge fee");
    }
}
