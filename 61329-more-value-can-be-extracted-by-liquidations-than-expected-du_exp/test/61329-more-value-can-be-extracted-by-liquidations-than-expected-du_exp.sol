// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./61329-more-value-can-be-extracted-by-liquidations-than-expected-du.sol";

/*//////////////////////////////////////////////////////////////////////////
    Driver for VII Finance finding #61329 — normalizedToFull uses totalSupply
    instead of the violator's tokenId balance, so liquidations seize excess value.
//////////////////////////////////////////////////////////////////////////*/
contract Vii61329Test is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.requestedAmount(), 75, "requested half of 150");
        assertEq(e.liquidatorValue(), 100, "bug seizes 100");
        assertEq(e.surplus(), 25, "excess 25 value units");
        assertGt(e.liquidatorValue(), e.requestedAmount(), "more value than expected");
        assertEq(e.valueToken().balanceOf(e.LIQUIDATOR()), 25, "profit marker");
    }

    /// @notice Control: when the borrower owns 100% of every tokenId, transfer is exact.
    function test_fullOwnership_isExact() public {
        ERC721WrapperBase w = new ERC721WrapperBase();
        w.seedWrap(1, address(this), 100);
        w.seedWrap(2, address(this), 100);
        w.enableTokenIdAsCollateral(1);
        w.enableTokenIdAsCollateral(2);

        address liquidator = address(0xA11CE);
        uint256 beforeBal = w.balanceOf(address(this)); // 200
        uint256 transferAmount = beforeBal / 2; // 100
        w.transfer(liquidator, transferAmount);

        uint256 liqVal = w.balanceOf(liquidator, 1) + w.balanceOf(liquidator, 2);
        assertEq(liqVal, transferAmount, "full ownership: exact transfer");
    }
}
