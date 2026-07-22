// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "./26477-h-01-last-nft-from-the-supply-cant-be-minted-pashov-none-mus.sol";

contract MuseumOfMahomesLastNftTest is Test {
    function test_last_nft_cannot_be_minted() public {
        Exploit exploit = new Exploit();
        MuseumOfMahomes museum = exploit.museum();
        uint256 MAX = exploit.MAX_SUPPLY();

        exploit.run();

        // All but the last NFT were minted.
        assertEq(museum.totalSupply(), MAX - 1, "should be one below MAX_SUPPLY");
        assertEq(museum.nextId(), MAX - 1, "nextId should be MAX_SUPPLY - 1");

        // The final NFT (tokenId MAX_SUPPLY-1) is permanently un-mintable.
        assertTrue(exploit.lastNftUnmintable(), "final mint should have reverted");
        assertEq(museum.ownerOf(MAX - 1), address(0), "final tokenId must never be minted");

        // Control: a direct attempt to mint the very last NFT reverts with
        // ExceedsMaxSupply, proving the `>=` off-by-one is what blocks it.
        vm.prank(address(exploit));
        vm.expectRevert(MuseumOfMahomes.ExceedsMaxSupply.selector);
        museum.mint(address(0xB0B), 1, false);
    }
}
