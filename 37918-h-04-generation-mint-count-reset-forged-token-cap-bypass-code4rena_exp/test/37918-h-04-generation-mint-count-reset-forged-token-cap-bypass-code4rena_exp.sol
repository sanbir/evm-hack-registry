// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TraitForgeNft, Exploit} from "./37918-h-04-generation-mint-count-reset-forged-token-cap-bypass-code4rena.sol";
import {Test} from "forge-std/Test.sol";

contract GenerationCounterResetTest is Test {
    function test_forgedEntityIsDroppedByGenerationRollover() public {
        Exploit exploit = new Exploit();
        TraitForgeNft nft = exploit.nft();
        exploit.run();

        assertEq(nft.currentGeneration(), 3, "rollover should leave generation 3 active");
        assertEq(nft.generationEntityCounts(2), 4, "generation 2 must exceed its three-entity cap");
        assertGt(nft.generationEntityCounts(2), nft.maxTokensPerGen());
        assertEq(nft.tokenGeneration(exploit.forgedToken()), 2);
    }

    function test_control_withoutForgingRespectsCap() public {
        TraitForgeNft nft = new TraitForgeNft();
        nft.mintToken();
        nft.mintToken();
        nft.mintToken();
        nft.mintToken();

        assertEq(nft.generationEntityCounts(1), 3);
        assertEq(nft.generationEntityCounts(2), 1);
        assertLe(nft.generationEntityCounts(2), nft.maxTokensPerGen());
    }
}
