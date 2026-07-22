// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20226-h-03-short-positions-can-be-burned-while-holding-collateral.sol";

/// @dev forge-std driver for the reduced Polynomial H-03 PoC. Drives the same
///      Exploit the Playground runs and re-asserts the harm independently.
contract ShortBurnWithCollateralTest is Test {
    Exploit exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    function test_burnLocksCollateral() public {
        exploit.run();

        ShortToken st = exploit.shortToken();
        ShortCollateral sc = exploit.shortCollateral();
        MockERC20 susd = exploit.susd();
        Exchange ex = exploit.exchange();
        uint256 id = exploit.positionId();
        address victim = address(exploit.victim());
        uint256 collateral = exploit.COLLATERAL();

        // Position was burned: ownerOf reverts NOT_MINTED.
        vm.expectRevert("NOT_MINTED");
        st.ownerOf(id);

        // Collateral is still recorded against the burned position...
        (, uint256 remShort, uint256 remColl,) = st.shortPositions(id);
        assertEq(remShort, 0, "short should be zero");
        assertEq(remColl, collateral, "collateral should still be recorded");

        // ...and still physically held by ShortCollateral...
        assertEq(susd.balanceOf(address(sc)), collateral, "collateral should be stuck in custody");

        // ...while the victim got nothing back.
        assertEq(susd.balanceOf(victim), 0, "victim should have recovered nothing");

        // Any attempt to return the collateral reverts (owner lookup fails).
        vm.expectRevert("NOT_MINTED");
        ex.recoverCollateral(id, collateral);
    }
}
