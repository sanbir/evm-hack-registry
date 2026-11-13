// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Asset, TransferProxy, Escrow, PoolManagerFixed} from "./35790-assets-can-get-stuck-in-transferproxy-spearbit-none-centrifu.sol";

contract Finding35790Test is Test {
    function test_exploit_leaves_the_assets_in_the_proxy() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stuck(), e.AMOUNT(), "1_000_000 tokens stuck in the proxy");
        assertEq(e.escrowBalance(), 0, "escrow received nothing");
        assertTrue(e.pulled() == false, "pull failed");
    }

    function test_control_allowance_lets_the_escrow_take_the_tokens() public {
        Asset asset = new Asset();
        TransferProxy proxy = new TransferProxy();
        Escrow escrow = new Escrow();
        PoolManagerFixed manager = new PoolManagerFixed(proxy, escrow, address(asset));
        asset.mint(address(proxy), 1_000_000 ether);
        assertTrue(manager.transferAssets(address(asset), 1_000_000 ether), "pull");
        assertEq(asset.balanceOf(address(proxy)), 0, "proxy is empty");
        assertEq(asset.balanceOf(address(escrow)), 1_000_000 ether, "escrow received the tokens");
    }
}
