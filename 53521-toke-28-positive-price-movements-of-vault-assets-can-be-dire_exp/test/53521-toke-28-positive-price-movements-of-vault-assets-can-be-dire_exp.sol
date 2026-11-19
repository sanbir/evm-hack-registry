// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, ERC20Mini, DestinationVault} from "./53521-toke-28-positive-price-movements-of-vault-assets-can-be-dire.sol";

contract Toke28Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_staleDebtAndZeroMinSkims100Ether() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.userGot(), 100 ether, "withdrawer is paid the stale 100 ether");
        assertEq(exp.skimmed(), 100 ether, "100 ether of appreciation is skimmed");
        assertEq(exp.eth().balanceOf(SINK), 100 ether, "skim sits at the sink");
        assertEq(exp.eth().balanceOf(address(exp)), 100 ether, "user received only the stale leg");
        assertEq(exp.dest().sharesA(), 0, "all 100 dvA were liquidated");
    }

    function test_control_minAmountOutAtFairValueReverts() public {
        ERC20Mini eth = new ERC20Mini("WETH");
        DestinationVault dest = new DestinationVault(eth);
        eth.mint(address(dest), 200 ether);

        vm.expectRevert(bytes("slippage"));
        dest.withdrawBaseAsset(100 ether, 200 ether);

        assertEq(dest.lastSkim(), 0, "nothing was skimmed");
        assertEq(eth.balanceOf(SINK), 0, "control does not move 100 ether");
        assertEq(eth.balanceOf(address(dest)), 200 ether, "fair value stays in the vault");
        assertEq(dest.sharesA(), 100 ether, "dvA was not burned");
    }
}
