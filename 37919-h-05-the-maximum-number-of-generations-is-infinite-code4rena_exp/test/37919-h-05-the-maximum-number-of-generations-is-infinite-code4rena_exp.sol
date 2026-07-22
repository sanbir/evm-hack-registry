// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TraitForgeNft, Exploit} from "./37919-h-05-the-maximum-number-of-generations-is-infinite-code4rena.sol";

contract InfiniteGenerationsTest is Test {
    /// @notice CONTROL — minting exactly up to the intended cap works as
    ///         designed: generations fill in order and the loop tracks the
    ///         intended supply.
    function test_mintingWithinCap_worksAsIntended() public {
        TraitForgeNft nft = new TraitForgeNft();
        uint256 maxGen = nft.maxGeneration();
        uint256 perGen = nft.maxTokensPerGen();

        // Mint one short of the full intended supply — generation should
        // still be within [1, maxGen].
        for (uint256 i = 0; i < (maxGen * perGen) - 1; i++) {
            nft.mintToken();
        }
        assertLe(nft.getGeneration(), maxGen);
    }

    /// @notice HARM — after minting exactly the intended max supply
    ///         (maxGeneration x maxTokensPerGen), currentGeneration has
    ///         already rolled PAST the cap with no revert, and the protocol
    ///         keeps accepting mints indefinitely.
    function test_generationCap_isNotEnforced() public {
        Exploit exploit = new Exploit();
        TraitForgeNft nft = exploit.nft();

        uint256 maxGen = nft.maxGeneration();
        uint256 perGen = nft.maxTokensPerGen();
        uint256 intendedMaxSupply = maxGen * perGen;

        exploit.run();

        // The generation counter is beyond the intended maximum.
        assertGt(nft.getGeneration(), maxGen);

        // Total supply exceeds the protocol's advertised fixed maximum.
        assertGt(nft.totalMinted(), intendedMaxSupply);
        assertEq(nft.totalMinted(), intendedMaxSupply + perGen);

        // And nothing stops a further mint into this uncapped generation —
        // the "maximum" is not actually a ceiling.
        nft.mintToken();
        assertEq(nft.totalMinted(), intendedMaxSupply + perGen + 1);
    }
}
