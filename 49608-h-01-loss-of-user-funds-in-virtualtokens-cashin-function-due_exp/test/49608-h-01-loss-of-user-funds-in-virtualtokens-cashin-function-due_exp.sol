// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, VirtualTokenFixed} from "./49608-h-01-loss-of-user-funds-in-virtualtokens-cashin-function-due.sol";

contract Finding49608Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_erc20_mints_zero() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 0, "0 shares");
        assertEq(e.asset().balanceOf(address(e.token())), 100 ether, "100 pulled");
        assertEq(e.marker().balanceOf(SINK), 100 ether, "100 locked");
    }

    function test_control_mints_the_amount() public {
        Asset asset = new Asset();
        VirtualTokenFixed token = new VirtualTokenFixed(asset);
        asset.mint(address(this), 100 ether);
        asset.approve(address(token), 100 ether);
        token.cashIn(100 ether);
        assertEq(token.balanceOf(address(this)), 100 ether, "100 shares");
        assertEq(asset.balanceOf(address(token)), 100 ether, "100 pulled");
    }
}
