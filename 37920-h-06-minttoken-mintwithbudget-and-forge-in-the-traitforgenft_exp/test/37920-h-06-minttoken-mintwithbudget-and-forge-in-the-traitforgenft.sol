// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  TraitForge EntropyGenerator — Code4rena H-06, July 2024
    initializeAlphaIndices is `onlyOwner`. TraitForgeNft._incrementGeneration
    is what actually calls it, once a generation hits maxTokensPerGen. The
    owner check reverts, so mintToken, mintWithBudget, and forge cannot open
    the next generation. With maxTokensPerGen = 1, every entry point reverts
    and no NFT is issued.

    Verbatim signature: function initializeAlphaIndices() public whenNotPaused onlyOwner
    Call site: entropyGenerator.initializeAlphaIndices()
*/

contract EntropyGenerator {
    address public owner;
    address public allowedCaller;
    bool public paused;
    bool public initialized;
    bool public fixedInitialized;

    modifier onlyOwner() {
        require(msg.sender == owner, "onlyOwner"); // @> VULN: initializeAlphaIndices is onlyOwner, so TraitForgeNft cannot call it
        _;
    }

    modifier onlyAllowedCaller() {
        require(msg.sender == allowedCaller, "onlyAllowedCaller");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    function setAllowedCaller(address caller) external onlyOwner {
        allowedCaller = caller;
    }

    function initializeAlphaIndices() public whenNotPaused onlyOwner {
        initialized = true;
    }

    /// @notice Recommended modifier. Not used by run().
    function initializeAlphaIndicesFixed() public whenNotPaused onlyAllowedCaller {
        fixedInitialized = true;
    }
}

contract TraitForgeNft {
    EntropyGenerator public entropyGenerator;
    uint256 public currentGeneration = 1;
    uint256 public maxTokensPerGen = 1;
    uint256 public priceIncrement = 1 ether;
    uint256 public priceIncrementByGen = 0.1 ether;
    mapping(uint256 => uint256) public generationMintCounts;
    bool public useFix;
    uint256 public failedMints;

    constructor(EntropyGenerator _entropy) {
        entropyGenerator = _entropy;
    }

    function setUseFix(bool v) external {
        useFix = v;
    }

    function _incrementGeneration() private {
        require(generationMintCounts[currentGeneration] >= maxTokensPerGen, "Generation limit not yet reached");
        currentGeneration++;
        generationMintCounts[currentGeneration] = 0;
        priceIncrement = priceIncrement + priceIncrementByGen;
        if (useFix) {
            entropyGenerator.initializeAlphaIndicesFixed();
        } else {
            entropyGenerator.initializeAlphaIndices(); // @> VULN call site: mint/forge die here
        }
    }

    function mintToken() public {
        generationMintCounts[currentGeneration] += 1;
        if (generationMintCounts[currentGeneration] >= maxTokensPerGen) {
            _incrementGeneration();
        }
    }

    function mintWithBudget() public {
        mintToken();
    }

    function forge() public {
        mintToken();
    }

    function tryMint() external returns (bool ok) {
        try this.mintToken() {
            ok = true;
        } catch {
            failedMints += 1;
            ok = false;
        }
    }

    function tryMintWithBudget() external returns (bool ok) {
        try this.mintWithBudget() {
            ok = true;
        } catch {
            failedMints += 1;
            ok = false;
        }
    }

    function tryForge() external returns (bool ok) {
        try this.forge() {
            ok = true;
        } catch {
            failedMints += 1;
            ok = false;
        }
    }
}

contract Exploit {
    EntropyGenerator public entropy; // CREATE nonce 1 — vulnerable
    TraitForgeNft public nft; // CREATE nonce 2

    constructor() {
        entropy = new EntropyGenerator(address(this));
        nft = new TraitForgeNft(entropy);
        entropy.setAllowedCaller(address(nft));
    }

    function run() external {
        bool mintOk = nft.tryMint();
        bool budgetOk = nft.tryMintWithBudget();
        bool forgeOk = nft.tryForge();
        require(!mintOk, "mintToken should revert");
        require(!budgetOk, "mintWithBudget should revert");
        require(!forgeOk, "forge should revert");
        require(nft.failedMints() == 3, "three entry points failed");
        require(nft.currentGeneration() == 1, "generation did not advance");
        require(nft.generationMintCounts(1) == 0, "no mint stuck");
        require(!entropy.initialized(), "indices were not initialized");
    }
}
