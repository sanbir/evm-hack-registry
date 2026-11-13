// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, RTokenFixed} from
    "./57190-rtoken-is-not-interest-bearing-due-to-broken-liquidity-index.sol";

contract Finding57190Test is Test {
    function test_exploit_burn_pays_principal_and_strands_interest() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.scaled(), 2000 ether, "scaled");
        assertEq(e.received(), 1000 ether, "paid");
        assertEq(e.stuck(), 1000 ether, "stuck");
        assertEq(e.asset().balanceOf(address(e)), 1000 ether, "user");
    }

    function test_control_burn_pays_the_scaled_amount() public {
        Asset asset = new Asset();
        RTokenFixed fixedR = new RTokenFixed(asset);
        fixedR.mint(address(this), 1000 ether);
        asset.mint(address(fixedR), 2000 ether);
        (uint256 paid,,) = fixedR.burn(address(this), address(this), 1000 ether, 2e27);
        assertEq(paid, 2000 ether, "interest paid");
        assertEq(asset.balanceOf(address(this)), 2000 ether, "user");
        assertEq(asset.balanceOf(address(fixedR)), 0, "pool empty");
    }
}
