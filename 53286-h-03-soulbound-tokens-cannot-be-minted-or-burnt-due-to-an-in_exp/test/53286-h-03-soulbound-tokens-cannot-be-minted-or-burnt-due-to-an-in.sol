// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Gigaverse finding 53286 (H-03):
// "Soulbound tokens cannot be minted or burnt due to an invalid check".
//
// Real audited source (the vulnerable `_update` override is reproduced VERBATIM,
// the vulnerable line is marked @>):
//   protocol Gigaverse (Pashov Audit Group, Gigaverse-security-review 2025-01-18)
//   contract GameNFT  (inherited by GigaNoobNFT and GigaNameNFT)
//   fn       _update(address to, uint256 tokenId, address auth)  — overrides ERC721._update
//   report   github.com/pashov/audits/.../Gigaverse-security-review_2025-01-18.md
//
// Root cause: `_update` is called by OpenZeppelin ERC721 on EVERY mint, transfer
// and burn. The override unconditionally reverts when the token's IS_SOULBOUND
// doc value is true:
//     require(!isSoulbound, "GameNFT: Token is soulbound");   // @> VULN
// A soulbound token is minted with prevOwner == address(0) and burnt with
// to == address(0); the check does not distinguish those cases from a transfer,
// so it fires during mint AND burn. Consequently a soulbound token can NEVER be
// minted (the mint tx reverts) and, once soulbound, can NEVER be burnt (the burn
// tx reverts) — a permanent DoS of the soulbound feature. The recommended fix
// only blocks the check when prevOwner != 0 AND to != 0 (an actual transfer).
//
// The vulnerable override is byte-for-byte the audited source. The ERC721 base
// (`_update`/`_mint`/`_burn`/`_ownerOf`) is a faithful minimal OZ-v5 double, and
// the doc-value storage read by `getDocBoolValue` is a faithful minimal double of
// GameNFT's on-chain document store.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Optional pre-update hook interface referenced by the verbatim override.
interface IERC721UpdateHandler {
    function update(address collection, address to, uint256 tokenId, address auth) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful minimal ERC721 base (OpenZeppelin v5 `_update` model). `_mint` and
// `_burn` both route through `_update`, which is exactly why the buggy override
// intercepts mints and burns as well as transfers.
// ─────────────────────────────────────────────────────────────────────────────
abstract contract ERC721 {
    mapping(uint256 => address) internal _owners;
    mapping(address => uint256) internal _balances;

    function _ownerOf(uint256 tokenId) internal view returns (address) {
        return _owners[tokenId];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "ERC721: nonexistent token");
        return owner;
    }

    function balanceOf(address owner) public view returns (uint256) {
        return _balances[owner];
    }

    /// @notice OZ-v5 core transfer primitive. Returns the previous owner.
    function _update(address to, uint256 tokenId, address /*auth*/) internal virtual returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0)) {
            _balances[from] -= 1;
        }
        if (to != address(0)) {
            _balances[to] += 1;
        }
        _owners[tokenId] = to;
        return from;
    }

    function _mint(address to, uint256 tokenId) internal {
        require(to != address(0), "ERC721: mint to the zero address");
        address previousOwner = _update(to, tokenId, address(0));
        require(previousOwner == address(0), "ERC721: token already minted");
    }

    function _burn(uint256 tokenId) internal {
        address previousOwner = _update(address(0), tokenId, address(0));
        require(previousOwner != address(0), "ERC721: nonexistent token");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `GameNFT._update` is reproduced VERBATIM from the audited
// source (the `require(!isSoulbound, ...)` line is the @> vulnerable line).
// ─────────────────────────────────────────────────────────────────────────────
contract GameNFT is ERC721 {
    address public beforeUpdateHandler; // optional hook (address(0) => skipped, as here)

    // Faithful minimal double of GameNFT's document store: doc bool values keyed
    // by (tokenId, CID). getDocBoolValue reads it exactly like the real contract.
    mapping(uint256 => mapping(uint256 => bool)) internal _docBool;
    uint256 internal constant IS_SOULBOUND_CID = uint256(keccak256("IS_SOULBOUND"));

    function getDocBoolValue(uint256 tokenId, uint256 cid) public view returns (bool) {
        return _docBool[tokenId][cid];
    }

    // ── VERBATIM audited override ──
    function _update(
        address to,
        uint256 tokenId,
        address auth
    )
        internal
        virtual
        override(
            ERC721
        ) returns (address)
    {

         if (beforeUpdateHandler != address(0)) {
            IERC721UpdateHandler(
                    beforeUpdateHandler
                ).update(
                address(this),
                to,
                tokenId,
                auth
            );
        }

        address prevOwner = _ownerOf(tokenId);

        //...
        bool isSoulbound = getDocBoolValue(tokenId, IS_SOULBOUND_CID);
        require(!isSoulbound, "GameNFT: Token is soulbound"); // @> VULN: fires on mint (prevOwner==0) and burn (to==0) too, not only transfers -> soulbound tokens can never be minted or burnt
        //...

        return super._update(to, tokenId, auth);
    }

    // ── faithful public entry points (as GigaNoobNFT / GigaNameNFT would expose) ──

    /// @notice Mint a normal (non-soulbound) token. Succeeds — proves `_update` works.
    function mintNormal(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    /// @notice Mint a token whose IS_SOULBOUND doc value is true. The token
    ///         metadata is set to soulbound, then `_mint` routes through the buggy
    ///         `_update` — which reverts, so the mint can never complete.
    function mintSoulbound(address to, uint256 tokenId) external {
        _docBool[tokenId][IS_SOULBOUND_CID] = true;
        _mint(to, tokenId);
    }

    /// @notice Set/clear a token's IS_SOULBOUND doc value (faithful doc-store write).
    function setSoulbound(uint256 tokenId, bool v) external {
        _docBool[tokenId][IS_SOULBOUND_CID] = v;
    }

    /// @notice Burn a token (routes through `_update`).
    function burn(uint256 tokenId) external {
        _burn(tokenId);
    }

    /// @notice Non-reverting owner read for existence checks.
    function rawOwnerOf(uint256 tokenId) external view returns (address) {
        return _ownerOf(tokenId);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// DoS marker — the harm (soulbound tokens permanently unmintable / unburnable)
// transfers nothing to the attacker, so its magnitude is recorded on this marker
// minted to the SINK: one unit per soulbound token permanently bricked.
// ─────────────────────────────────────────────────────────────────────────────
contract SoulboundDoSMarker {
    string public name = "Soulbound tokens permanently unmintable/unburnable";
    string public symbol = "SBLCK";
    uint8 public constant decimals = 0;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a normal token mints fine, but a soulbound token can never be
// minted and, once soulbound, can never be burnt — both revert on the buggy check.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER = address(0xBEEF);

    GameNFT public nft;
    SoulboundDoSMarker public marker;

    uint256 public soulboundMintBlocked; // 1 if the soulbound mint reverted
    uint256 public soulboundBurnBlocked; // 1 if the soulbound burn reverted
    bool public normalMintOk;

    constructor() {
        nft = new GameNFT();               // child nonce 1 (VULN)
        marker = new SoulboundDoSMarker(); // child nonce 2 (marker)
    }

    function run() external {
        // CONTROL: a normal (non-soulbound) token mints fine — proves `_update` works.
        nft.mintNormal(USER, 1);
        normalMintOk = (nft.ownerOf(1) == USER);
        require(normalMintOk, "control: normal mint should succeed");

        // HARM 1: a soulbound token can NEVER be minted — the buggy check reverts on mint.
        try nft.mintSoulbound(USER, 2) {
            // unreachable under the bug
        } catch {
            soulboundMintBlocked = 1;
            marker.mint(SINK, 1); // 1 soulbound token permanently unmintable
        }
        require(nft.rawOwnerOf(2) == address(0), "soulbound token must not exist");

        // HARM 2: an existing soulbound token can NEVER be burnt — same check reverts on burn.
        nft.mintNormal(USER, 3);      // token exists (created non-soulbound)
        nft.setSoulbound(3, true);    // its IS_SOULBOUND doc value is set -> token is soulbound
        try nft.burn(3) {
            // unreachable under the bug
        } catch {
            soulboundBurnBlocked = 1;
            marker.mint(SINK, 1); // 1 soulbound token permanently unburnable (locked)
        }
        require(nft.ownerOf(3) == USER, "soulbound token must remain stuck (unburnable)");

        // Concrete DoS harm, recorded on the marker at the SINK.
        require(soulboundMintBlocked == 1, "mint DoS not reproduced");
        require(soulboundBurnBlocked == 1, "burn DoS not reproduced");
        require(marker.balanceOf(SINK) == 2, "DoS magnitude not recorded");
    }
}
