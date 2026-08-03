// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TraitForgeNft} from "../src/traitforge/contracts/TraitForgeNft/TraitForgeNft.sol";
import {EntropyGenerator} from "../src/traitforge/contracts/EntropyGenerator/EntropyGenerator.sol";
import {EntityForging} from "../src/traitforge/contracts/EntityForging/EntityForging.sol";
import {Airdrop} from "../src/traitforge/contracts/Airdrop/Airdrop.sol";
import {NukeFund} from "../src/traitforge/contracts/NukeFund/NukeFund.sol";

/// @title Code4rena TraitForge H-01 (#37915) — mintWithBudget uses the global
///        `_tokenIds` supply counter instead of the per-generation counter.
///
/// Every contract on the mint path is the UNMODIFIED audited source, compiled
/// from https://github.com/code-423n4/2024-07-traitforge at commit 72077d0 with
/// the project's real OpenZeppelin contracts 4.9.3 dependency:
///   - TraitForgeNft    (the vulnerable contract)
///   - EntropyGenerator (real, owned by the NFT, serves getNextEntropy)
///   - EntityForging    (real, queried on every transfer via getListedTokenIds)
///   - Airdrop          (real, owned by the NFT, addUserAmount on every mint)
///   - NukeFund         (real, receives the mint proceeds via _distributeFunds)
///
/// The bug lives at TraitForgeNft.sol:215
///     while (budgetLeft >= mintPrice && _tokenIds < maxTokensPerGen) { ... }
/// `_tokenIds` counts tokens minted across ALL generations, so once generation 1
/// is full (`_tokenIds == 10000`) the loop guard is permanently false and
/// mintWithBudget mints ZERO tokens in every later generation — even though each
/// new generation reopens 10,000 fresh mint slots.
contract PoC_37915 is Test {
    TraitForgeNft internal nft;
    EntropyGenerator internal entropy;
    EntityForging internal forging;
    Airdrop internal airdrop;
    NukeFund internal nukeFund;

    // Storage slots from `forge inspect TraitForgeNft storage-layout`.
    uint256 internal constant SLOT_GEN_MINT_COUNTS = 27; // generationMintCounts mapping
    uint256 internal constant SLOT_TOKEN_IDS = 30;       // private _tokenIds

    address internal constant DEV = address(0xDe7);
    address internal constant DAO = address(0xDa0);
    address internal attacker = address(0xA11CE);

    bytes32[] internal EMPTY_PROOF; // whitelist disabled -> proof unused

    receive() external payable {}

    function setUp() public {
        nft = new TraitForgeNft();
        entropy = new EntropyGenerator(address(nft));
        forging = new EntityForging(address(nft));
        airdrop = new Airdrop();
        nukeFund = new NukeFund(address(nft), address(airdrop), payable(DEV), payable(DAO));

        // Wire the protocol exactly as the deployment scripts do.
        nft.setEntropyGenerator(address(entropy));
        nft.setEntityForgingContract(address(forging));
        nft.setAirdropContract(address(airdrop));
        nft.setNukeFundContract(payable(address(nukeFund)));

        // The NFT drives EntropyGenerator.initializeAlphaIndices() on every
        // generation increment and Airdrop.addUserAmount() on every mint; both
        // are onlyOwner, so ownership is handed to the NFT (production wiring).
        entropy.transferOwnership(address(nft));
        airdrop.transferOwnership(address(nft));

        // Model the public-sale phase (whitelist window elapsed).
        nft.setWhitelistEndTime(0);
    }

    /// @dev Reads the private `_tokenIds` counter directly from storage.
    function _tokenIds() internal view returns (uint256) {
        return uint256(vm.load(address(nft), bytes32(SLOT_TOKEN_IDS)));
    }

    function _genCountSlot(uint256 gen) internal pure returns (bytes32) {
        return keccak256(abi.encode(gen, SLOT_GEN_MINT_COUNTS));
    }

    function testMintWithBudgetBrickedFromGenerationTwo() public {
        // ---------------------------------------------------------------
        // PART A — the real mint path works and increments BOTH counters.
        // ---------------------------------------------------------------
        for (uint256 i = 0; i < 3; i++) {
            uint256 p = nft.calculateMintPrice();
            vm.deal(address(this), p);
            nft.mintToken{value: p}(EMPTY_PROOF);
        }
        assertEq(nft.totalSupply(), 3, "3 real gen-1 mints");
        assertEq(nft.generationMintCounts(1), 3, "gen-1 counter");
        assertEq(_tokenIds(), 3, "global counter tracks gen-1 mints");

        // ---------------------------------------------------------------
        // PART B — compress the remaining generation-1 history.
        // Filling all 10,000 gen-1 tokens on-chain is exactly reachable by
        // repeating PART A; we advance the two counters PART A just proved move
        // together (within gen 1, _tokenIds == generationMintCounts[1]) to the
        // generation boundary so the trace stays readable. No contract code is
        // modified and every subsequent call runs on real logic.
        // ---------------------------------------------------------------
        uint256 maxPerGen = nft.maxTokensPerGen(); // 10_000
        vm.store(address(nft), bytes32(SLOT_TOKEN_IDS), bytes32(maxPerGen - 1));
        vm.store(address(nft), _genCountSlot(1), bytes32(maxPerGen - 1));
        assertEq(_tokenIds(), maxPerGen - 1, "seeded global counter = 9999");
        assertEq(nft.generationMintCounts(1), maxPerGen - 1, "seeded gen-1 counter = 9999");
        assertEq(nft.currentGeneration(), 1, "still generation 1");

        // ---------------------------------------------------------------
        // PART C — cross into generation 2 through the REAL code path.
        // ---------------------------------------------------------------
        uint256 p1 = nft.calculateMintPrice();
        vm.deal(address(this), p1);
        nft.mintToken{value: p1}(EMPTY_PROOF); // 10,000th gen-1 token -> fills gen 1
        assertEq(nft.generationMintCounts(1), maxPerGen, "gen-1 now full");
        assertEq(nft.currentGeneration(), 1, "increment happens on the NEXT mint");

        uint256 p2 = nft.calculateMintPrice();
        vm.deal(address(this), p2);
        nft.mintToken{value: p2}(EMPTY_PROOF); // triggers _incrementGeneration -> gen 2
        assertEq(nft.currentGeneration(), 2, "real _incrementGeneration ran");
        assertEq(nft.generationMintCounts(2), 1, "1 token minted in fresh gen 2");
        assertEq(_tokenIds(), maxPerGen + 1, "global counter now exceeds maxTokensPerGen");

        // Generation 2 has 9,999 free slots; a correct mintWithBudget with this
        // budget would mint ~198 of them.
        uint256 genTwoPrice = nft.calculateMintPrice();
        uint256 budget = 1 ether;
        uint256 wouldMint = budget / genTwoPrice; // lower bound (price is ~flat here)

        // ---------------------------------------------------------------
        // PART D — THE EXPLOIT: a whitelisted user batch-mints in generation 2.
        // ---------------------------------------------------------------
        vm.deal(attacker, budget);
        uint256 supplyBefore = nft.totalSupply();

        vm.prank(attacker);
        nft.mintWithBudget{value: budget}(EMPTY_PROOF);

        // HARM: zero tokens minted, entire budget refunded, despite ~198 payable
        // slots being available in generation 2.
        assertEq(nft.balanceOf(attacker), 0, "attacker minted ZERO tokens");
        assertEq(attacker.balance, budget, "entire budget refunded (nothing spent)");
        assertEq(nft.totalSupply(), supplyBefore, "supply unchanged");
        assertEq(nft.generationMintCounts(2), 1, "gen 2 still has 9,999 free slots");
        assertGt(wouldMint, 100, "a correct guard would have minted 100+ tokens here");

        // ---------------------------------------------------------------
        // PART E — CONTROL: mintToken (no _tokenIds guard) still mints in gen 2,
        // proving the generation is open and mintWithBudget alone is bricked.
        // ---------------------------------------------------------------
        uint256 pc = nft.calculateMintPrice();
        vm.deal(attacker, pc);
        vm.prank(attacker);
        nft.mintToken{value: pc}(EMPTY_PROOF);

        assertEq(nft.balanceOf(attacker), 1, "mintToken succeeds in generation 2");
        assertEq(nft.generationMintCounts(2), 2, "generation 2 accepts new mints");
        uint256 lastId = maxPerGen + 2; // token #10002
        assertEq(nft.getTokenGeneration(lastId), 2, "control token belongs to gen 2");

        emit log_named_uint("gen-2 tokens minted by mintWithBudget", 0);
        emit log_named_uint("gen-2 tokens a correct guard would mint (>=)", wouldMint);
    }
}
