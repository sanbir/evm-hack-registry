// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30090-h-03-verbstokentokenuri-is-vulnerable-to-json-injection-atta.sol";

contract JsonInjectionTest is Test {
    Exploit internal exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    function test_exploit() public {
        exploit.run();

        // Re-assert the harm from outside run(): the minted NFT's tokenURI
        // resolves through Descriptor to a JSON payload containing an
        // injected fake image key that was never part of the piece voters saw.
        CultureIndex ci = exploit.cultureIndex();
        Descriptor desc = exploit.descriptor();
        VerbsToken vt = exploit.verbsToken();
        uint256 pieceId = exploit.pieceId();
        uint256 tokenId = exploit.tokenId();

        string memory votedImage = ci.getPieceImage(pieceId);
        assertEq(keccak256(bytes(votedImage)), keccak256(bytes("ipfs://realMonaLisa")), "voted image mismatch");

        (string memory nm, string memory de, string memory img, string memory an) = ci.pieceMetadata(pieceId);
        string memory rawJson = desc.buildJSON(nm, de, img, an);

        assertTrue(_contains(bytes(rawJson), bytes("ipfs://fakeMonaLisa")), "fake image not injected");
        assertTrue(_contains(bytes(rawJson), bytes("ipfs://realMonaLisa")), "real image should remain as bait");

        string memory uri = vt.tokenURI(tokenId);
        assertTrue(bytes(uri).length > 0, "tokenURI empty");
    }

    /// @notice Control: an honest piece (no injection payload) round-trips
    ///         cleanly and its tokenURI JSON contains only the honest image.
    function test_honestPiece_noInjection() public {
        CultureIndex ci = new CultureIndex();
        Descriptor desc = new Descriptor();
        VerbsToken vt = new VerbsToken(address(ci), address(desc));

        CreatorBps[] memory creators = new CreatorBps[](1);
        creators[0] = CreatorBps({creator: address(this), bps: 10_000});
        ArtPieceMetadata memory metadata = ArtPieceMetadata({
            name: "Honest Piece",
            description: "Nothing malicious here",
            image: "ipfs://honestImage",
            text: "",
            animationUrl: "ipfs://honestAnimation"
        });
        uint256 pieceId = ci.createPiece(metadata, creators);
        ci.vote(pieceId);
        uint256 tokenId = vt.mint();

        (string memory nm, string memory de, string memory img, string memory an) = ci.pieceMetadata(pieceId);
        string memory rawJson = desc.buildJSON(nm, de, img, an);
        assertFalse(_contains(bytes(rawJson), bytes("fakeMonaLisa")), "no injection expected");

        string memory uri = vt.tokenURI(tokenId);
        assertTrue(bytes(uri).length > 0, "tokenURI empty");
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || haystack.length < needle.length) return false;
        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
