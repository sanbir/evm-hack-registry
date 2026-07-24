// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./25133-h-04-in-execute-the-amount-routers-pay-is-what-user-signed-b.sol";

/*//////////////////////////////////////////////////////////////
    Connext — routers pay signed amount, credit bridgedAmt (#25133)
//////////////////////////////////////////////////////////////*/
contract ConnextRouterSlippageTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        uint256 seed = e.ROUTER_SEED();
        uint256 debit = (e.SIGNED() * e.bridge().LIQ_FEE_NUM()) / e.bridge().LIQ_FEE_DEN();
        uint256 expected = seed - debit + e.BRIDGED();
        assertEq(e.bridge().routerBalances(e.router(), address(e.local())), expected);
        assertGt(seed - expected, 9 ether, "router lost >9 from slippage gap");
    }
}
