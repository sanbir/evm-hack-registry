// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20224-h-01-exchange-liquidate-function-can-cause-liquidator-to-bur.sol";

/*//////////////////////////////////////////////////////////////
    Polynomial -- liquidator burns too much powerPerp (H-01, #20224)
//////////////////////////////////////////////////////////////////////////*/
contract PolynomialOverBurnLiquidationTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.powerPerp().balanceOf(address(e.liquidator())), 0, "all powerPerp burned");
        assertEq(e.collateral().balanceOf(address(e.liquidator())), e.COLL_AMT(), "only capped coll received");
    }
}
