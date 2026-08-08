// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    TraitForge — [H-06] initializeAlphaIndices uses onlyOwner
    (Code4rena 2024-07-traitforge, finding #37920, inzinko).

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.  TraitForgeNft
    is the configured allowed caller of EntropyGenerator, but the blamed
    function is restricted to the owner.  A generation rollover therefore
    reverts whenever the NFT contract calls initializeAlphaIndices, bricking
    mintToken/mintWithBudget/forge at the rollover boundary.
*/

contract EntropyGenerator {
    address public owner;
    address public allowedCaller;
    bool public paused;
    uint256 public alphaIndexVersion;

    constructor() {
        owner = msg.sender;
    }

    modifier whenNotPaused() {
        require(!paused, 'paused');
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, 'Ownable: caller is not the owner');
        _;
    }

    modifier onlyAllowedCaller() {
        require(msg.sender == allowedCaller, 'caller is not allowed');
        _;
    }

    function setAllowedCaller(address caller) external onlyOwner {
        allowedCaller = caller;
    }

    // The audited source line is preserved verbatim.  It should use
    // onlyAllowedCaller so TraitForgeNft can invoke it during rollover.
    function initializeAlphaIndices() public whenNotPaused onlyOwner { // @> VULN: NFT is the intended caller, but onlyOwner rejects it
        alphaIndexVersion++;
    }

    // Control helper: the owner can still initialize the indices, proving
    // that the failure is an access-control mismatch rather than paused state.
    function ownerInitializeAlphaIndices() external onlyOwner {
        initializeAlphaIndices();
    }
}

contract TraitForgeNft {
    EntropyGenerator public entropyGenerator;
    uint256 public currentGeneration = 1;
    uint256 public maxTokensPerGen = 1;
    uint256 public generationMintCount;
    uint256 public totalMinted;

    constructor(EntropyGenerator generator) {
        entropyGenerator = generator;
    }

    function mintToken() external {
        totalMinted++;
        generationMintCount++;
        if (generationMintCount >= maxTokensPerGen) {
            _incrementGeneration();
        }
    }

    function _incrementGeneration() private {
        currentGeneration++;
        // In the real TraitForgeNft this call is reached by mintToken,
        // mintWithBudget and forge when the generation cap is reached.
        entropyGenerator.initializeAlphaIndices();
    }
}

contract Exploit {
    EntropyGenerator public entropy; // CREATE nonce 1
    TraitForgeNft public nft;         // CREATE nonce 2

    constructor() {
        entropy = new EntropyGenerator();
        nft = new TraitForgeNft(entropy);
        // The NFT is intentionally the allowed caller.  The vulnerable
        // onlyOwner modifier nevertheless permits only this Exploit owner.
        entropy.setAllowedCaller(address(nft));
    }

    function run() external {
        // NFT's first mint reaches the generation boundary and invokes
        // initializeAlphaIndices.  Catch the revert so the recorder sees a
        // successful attack transaction while the DoS is asserted below.
        (bool ok, ) = address(nft).call(abi.encodeWithSignature('mintToken()'));
        require(!ok, 'mint unexpectedly succeeded');
        require(nft.totalMinted() == 0, 'reverted mint changed state');
        require(nft.currentGeneration() == 1, 'reverted mint advanced generation');
        require(entropy.alphaIndexVersion() == 0, 'indices unexpectedly initialized');
    }

    function ownerInitialize() external {
        entropy.ownerInitializeAlphaIndices();
    }
}
