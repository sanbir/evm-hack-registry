// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit, Erc20, BondingCurve} from "./45307-h-02-incorrect-reserve-assignment-leads-to-reserve-mismatch.sol";
contract Finding45307Test is Test {
    function test_exploit_one_eth_buys_dust() public {
        Exploit e = new Exploit();
        e.run();
        assertLt(e.tokenOut(), 0.02 ether);
        assertGt(e.fairOut(), 80 ether);
        assertEq(e.ethToken().balanceOf(address(e.curve())), 6 ether);
    }
    function test_control_correct_reserves_buy_about_83_tokens() public {
        Erc20 ethToken = new Erc20("WETH");
        Erc20 bond = new Erc20("G8");
        BondingCurve curve = new BondingCurve(ethToken, bond);
        ethToken.mint(address(curve), 5 ether);
        bond.mint(address(curve), 500 ether);
        ethToken.mint(address(this), 1 ether);
        curve.handleMigrationFailed(5 ether, uint112(500 ether));
        // overwrite with the recommended assignment
        // control uses getAmountOut directly with the true orientation and a manual transfer
        uint256 fair = curve.getAmountOut(1 ether, 5 ether, 500 ether);
        ethToken.transfer(address(curve), 1 ether);
        assertGt(fair, 80 ether);
        assertEq(ethToken.balanceOf(address(curve)), 6 ether);
    }
}
