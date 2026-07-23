// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58333-h-01-router-address-validation-logic-error-prevents-valid-ro.sol";

/*//////////////////////////////////////////////////////////////
    Blackhole — inverted setRouter zero-address check (#58333)
//////////////////////////////////////////////////////////////*/
contract BlackholeRouterValidationTest is Test {
    function test_exploit_validRouterRejected_zeroRouterBricksLaunch() public {
        Exploit e = new Exploit();
        e.run{value: 1 ether}();

        // Valid non-zero router was rejected; manager was forced to address(0).
        assertTrue(e.setValidFailed(), "setRouter(valid) should fail");
        assertEq(e.manager().router(), address(0), "router cleared to zero");

        // Launch bricked; 1 ETH liquidity remains locked in the genesis pool.
        assertTrue(e.launchBricked(), "launch should brick");
        assertEq(e.lockedAfterBrick(), 1 ether, "1 ETH locked");
        assertFalse(e.pool().launched(), "pool not launched");
    }

    function test_control_validRouterAllowsLaunch() public {
        // Fresh manager that never clears the router — launch succeeds.
        MockRouter r = new MockRouter();
        MockGenesisPool p = new MockGenesisPool();
        GenesisPoolManager m = new GenesisPoolManager(address(r));
        p.fund{value: 1 ether}();
        m.launchPool(p);
        assertTrue(p.launched(), "launch ok with valid router");
        assertTrue(r.wasCalled(), "router interacted");
        assertEq(p.lockedNative(), 0, "liquidity released");
    }
}
