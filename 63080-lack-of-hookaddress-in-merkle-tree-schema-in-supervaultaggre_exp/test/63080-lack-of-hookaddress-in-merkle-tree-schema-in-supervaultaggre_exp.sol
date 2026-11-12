// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    AggregatorFixed,
    Asset,
    Exploit
} from "./63080-lack-of-hookaddress-in-merkle-tree-schema-in-supervaultaggre.sol";

contract Finding63080Test is Test {
    address internal constant HOOK_A = address(0xA11CE);
    address internal constant HOOK_B = address(0xB0B);

    function test_exploit_hook_b_reuses_hook_a_proof() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.taken(), 100 ether, "N moved");
        assertEq(e.asset().balanceOf(address(e)), 100 ether, "recipient");
        assertEq(e.asset().balanceOf(address(e.agg())), 0, "aggregator empty");
    }

    function test_control_hook_in_the_leaf_rejects_the_second_proof() public {
        Asset asset = new Asset();
        AggregatorFixed agg = new AggregatorFixed(asset);
        uint256 n = 100 ether;
        asset.mint(address(agg), n);
        bytes32 leaf = agg.leafFor(HOOK_A, abi.encode(n));
        agg.setRoot(leaf);
        bytes32[] memory proof = new bytes32[](0);

        vm.expectRevert(bytes("proof"));
        agg.execute(HOOK_B, n, proof);

        assertEq(asset.balanceOf(address(this)), 0, "nothing moved");
        assertEq(asset.balanceOf(address(agg)), n, "funds stay");
    }
}
