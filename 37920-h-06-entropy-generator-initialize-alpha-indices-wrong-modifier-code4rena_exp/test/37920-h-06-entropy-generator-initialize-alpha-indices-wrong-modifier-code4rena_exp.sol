// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EntropyGenerator, TraitForgeNft, Exploit} from "./37920-h-06-entropy-generator-initialize-alpha-indices-wrong-modifier-code4rena.sol";
import {Test} from "forge-std/Test.sol";

contract InitializeAlphaIndicesDosTest is Test {
    function test_nftCallerIsRejectedAtGenerationRollover() public {
        Exploit exploit = new Exploit();
        TraitForgeNft nft = exploit.nft();
        EntropyGenerator entropy = exploit.entropy();

        exploit.run();

        assertEq(nft.totalMinted(), 0, "reverted mint must not persist");
        assertEq(nft.currentGeneration(), 1, "generation must remain at one");
        assertEq(entropy.alphaIndexVersion(), 0, "indices were not initialized by NFT");
        assertEq(entropy.allowedCaller(), address(nft));
    }

    function test_control_ownerCanInitialize() public {
        Exploit exploit = new Exploit();
        exploit.ownerInitialize();
        assertEq(exploit.entropy().alphaIndexVersion(), 1);
    }
}
