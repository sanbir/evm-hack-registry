// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/traitforge/contracts/TraitForgeNft/TraitForgeNft.sol";
import "../src/traitforge/contracts/EntityForging/IEntityForging.sol";
import "../src/traitforge/contracts/EntropyGenerator/IEntropyGenerator.sol";
import "../src/traitforge/contracts/Airdrop/IAirdrop.sol";

contract TraitForgeMockEntropy is IEntropyGenerator {
    uint256 public next = 1;
    function setAllowedCaller(address) external {}
    function getAllowedCaller() external pure returns (address) { return address(0); }
    function writeEntropyBatch1() external {}
    function writeEntropyBatch2() external {}
    function writeEntropyBatch3() external {}
    function getNextEntropy() external returns (uint256 value) { value = next++; }
    function getPublicEntropy(uint256, uint256) external pure returns (uint256) { return 1; }
    function getLastInitializedIndex() external pure returns (uint256) { return 0; }
    function initializeAlphaIndices() external {}
    function deriveTokenParameters(uint256, uint256) external pure returns (uint256, uint256, uint256, bool) { return (0, 0, 0, false); }
}

contract TraitForgeMockAirdrop is IAirdrop {
    function setTraitToken(address) external {}
    function airdropStarted() external pure returns (bool) { return false; }
    function allowDaoFund() external {}
    function daoFundAllowed() external pure returns (bool) { return false; }
    function addUserAmount(address, uint256) external {}
    function subUserAmount(address, uint256) external {}
    function startAirdrop(uint256) external {}
    function claim() external {}
}

contract TraitForgeMockForging is IEntityForging {
    function setNukeFundAddress(address payable) external {}
    function setTaxCut(uint256) external {}
    function setOneYearInDays(uint256) external {}
    function setMinimumListingFee(uint256) external {}
    function listForForging(uint256, uint256) external {}
    function forgeWithListed(uint256, uint256) external payable returns (uint256) { return 0; }
    function fetchListings() external pure returns (Listing[] memory listings) { return listings; }
    function getListedTokenIds(uint256) external pure returns (uint256) { return 0; }
    function getListings(uint256) external pure returns (Listing memory) { return Listing(address(0), 0, false, 0); }
    function cancelListingForForging(uint256) external {}
}

/// Reproduces Code4rena TraitForge #37915 against the real mintWithBudget loop.
contract PoC_37915 is Test {
    TraitForgeNft internal nft;
    TraitForgeMockEntropy internal entropy;
    TraitForgeMockAirdrop internal airdrop;
    TraitForgeMockForging internal forging;

    receive() external payable {}

    function setUp() public {
        nft = new TraitForgeNft();
        entropy = new TraitForgeMockEntropy();
        airdrop = new TraitForgeMockAirdrop();
        forging = new TraitForgeMockForging();
        nft.setEntropyGenerator(address(entropy));
        nft.setAirdropContract(address(airdrop));
        nft.setEntityForgingContract(address(forging));
        nft.setNukeFundContract(payable(address(this)));
        // The audit finding is no longer gated by the whitelist proof.
        nft.setWhitelistEndTime(0);
    }

    function testGlobalTokenIdStopsMintingInFreshGeneration() public {
        // Keep the real contract's maxTokensPerGen but seed the same state that
        // exists immediately after generation 1 is full. `_tokenIds` is a
        // private counter, so locate its slot from the compiled layout rather
        // than replacing the audited contract with a model.
        uint256 maxPerGen = nft.maxTokensPerGen();
        // forge inspect TraitForgeNft storage-layout reports `_tokenIds` at
        // slot 30 and `currentGeneration` at slot 20 for this audited build.
        vm.store(address(nft), bytes32(uint256(30)), bytes32(maxPerGen));
        // `_incrementGeneration` is normally called by _mintInternal when the
        // previous generation reaches its limit; model that post-transition
        // state while preserving every other contract invariant.
        vm.store(address(nft), bytes32(uint256(20)), bytes32(uint256(2)));

        uint256 price = nft.calculateMintPrice();
        vm.deal(address(this), price);
        nft.mintWithBudget{value: price}(new bytes32[](0));

        // With the vulnerable `_tokenIds < maxTokensPerGen` condition, no
        // token is minted in generation 2 and the full budget is refunded.
        assertEq(nft.totalSupply(), 0);
        assertEq(nft.generationMintCounts(2), 0);
        assertEq(address(this).balance, price);
    }

}
