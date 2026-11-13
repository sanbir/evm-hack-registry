// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, VibeERC721, NFTMintSaleMultiple} from
    "./27820-nftmintsalemultiple-wont-work-if-other-minter-mints-tokens-w.sol";

contract Finding27820Test is Test {
    function test_intersecting_id_blocks_the_sale() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 1 ether);
        e.run{value: 1 ether}();
        assertTrue(e.buyReverted(), "buy reverted");
        assertEq(e.sale().sold(), 0, "sold");
        assertEq(e.sale().collected(), 0, "collected");
        assertEq(e.unsoldWei(), 1 ether, "unsold");
        assertEq(e.nft().ownerOf(7), address(e), "id owner");
        console2.log("unsold wei", e.unsoldWei());
        console2.log("collected wei", e.sale().collected());
    }

    function test_control_exclusive_minter_sells_the_id() public {
        VibeERC721 nft = new VibeERC721();
        NFTMintSaleMultiple sale = new NFTMintSaleMultiple(nft, 7, 1 ether);
        nft.setMinter(address(sale));

        address intruder = address(0xA11CE);
        vm.prank(intruder);
        vm.expectRevert(bytes("minter"));
        nft.mintWithId(intruder, 7);

        address buyer = address(0xB0B);
        vm.deal(address(this), 1 ether);
        sale.buyNFT{value: 1 ether}(buyer);
        assertEq(nft.ownerOf(7), buyer, "buyer owns id");
        assertEq(sale.sold(), 1, "sold");
        assertEq(sale.collected(), 1 ether, "collected");
        console2.log("control collected wei", sale.collected());
        console2.log("control sold", sale.sold());
    }
}
