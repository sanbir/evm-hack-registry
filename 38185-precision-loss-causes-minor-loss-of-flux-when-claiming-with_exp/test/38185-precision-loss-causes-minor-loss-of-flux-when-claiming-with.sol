// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — Precision loss causes minor loss of FLUX when claiming with NFTs
    (Immunefi, marchev, finding #38185)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground. The
    `claimableFlux` assignment is inlined VERBATIM from FluxToken.sol#L224
    (audited commit f1007439ad3a32e412468c4c42f62f676822dc1f) — an unnecessary
    `/ veMax` followed by `* veMax` round-trip that truncates precision before
    the value is scaled back up. The Exploit deploys a reduced FluxToken +
    veALCX + patron NFT, claims FLUX for one NFT, and shows the claimant
    receives strictly less FLUX than the mathematically equivalent formula
    (without the redundant round-trip) would have produced (no fork, no
    cheatcodes).

    Root cause: `claimableFlux = (((bpt * veMul) / veMax) * veMax * (fluxPerVe
    + BPS)) / BPS / fluxMul;` divides `bpt * veMul` by `veMax` and then
    immediately multiplies the (truncated) result back by the same `veMax`.
    Since integer division truncates, this round-trip is NOT the identity
    function — it silently discards the remainder of `(bpt * veMul) % veMax`,
    which is otherwise mathematically redundant (the fix simply removes both
    operations, leaving `bpt * veMul * (fluxPerVe + BPS) / BPS / fluxMul`).
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced veALCX: only the 4 constants `getClaimableFlux` reads.
///         Real values from VotingEscrow.sol (MULTIPLIER=2, MAXTIME=365 days,
///         fluxPerVeALCX=5000 bps, fluxMultiplier=4).
contract MockVeALCX {
    uint256 public constant MULTIPLIER = 2;
    uint256 public constant MAXTIME = 365 days;
    uint256 public fluxPerVeALCX = 5000;
    uint256 public fluxMultiplier = 4;
}

interface IMockVeALCX {
    function MULTIPLIER() external view returns (uint256);
    function MAXTIME() external view returns (uint256);
    function fluxPerVeALCX() external view returns (uint256);
    function fluxMultiplier() external view returns (uint256);
}

/// @notice Reduced patron NFT: only `ownerOf` + `tokenData`.
contract PatronNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public tokenData;

    function mint(address to, uint256 tokenId, uint256 data) external {
        ownerOf[tokenId] = to;
        tokenData[tokenId] = data;
    }
}

/// @notice Reduced FluxToken: `calculateBPT` here already applies the `/ BPS`
///         division (that is a SEPARATE, independently-reported bug —
///         AuditVault #38191 — out of scope for this reduction so it doesn't
///         mask the precision-loss defect below). `getClaimableFlux` is
///         otherwise verbatim from FluxToken.sol#L215-L230.
contract FluxToken {
    address public veALCX;
    address public patronNFT;

    uint256 internal constant BPS = 10_000;
    uint256 public bptMultiplier = 40; // 0.4%

    mapping(uint256 => bool) public claimed;
    mapping(address => uint256) public balanceOf;

    constructor(address _veALCX, address _patronNFT) {
        veALCX = _veALCX;
        patronNFT = _patronNFT;
    }

    function calculateBPT(uint256 _amount) public view returns (uint256 bptOut) {
        bptOut = (_amount * bptMultiplier) / BPS;
    }

    // Verbatim from FluxToken.sol#L215-L230 (patronNFT branch only).
    function getClaimableFlux(uint256 _amount) public view returns (uint256 claimableFlux) {
        uint256 bpt = calculateBPT(_amount);

        uint256 veMul = IMockVeALCX(veALCX).MULTIPLIER();
        uint256 veMax = IMockVeALCX(veALCX).MAXTIME();
        uint256 fluxPerVe = IMockVeALCX(veALCX).fluxPerVeALCX();
        uint256 fluxMul = IMockVeALCX(veALCX).fluxMultiplier();

        // @> VULN: unnecessary "/ veMax" immediately followed by "* veMax" —
        // integer division truncates (bpt * veMul) before scaling back up,
        // silently discarding the remainder as dust every single claim.
        claimableFlux = (((bpt * veMul) / veMax) * veMax * (fluxPerVe + BPS)) / BPS / fluxMul;
        // FIX: claimableFlux = (bpt * veMul * (fluxPerVe + BPS)) / BPS / fluxMul;
    }

    function nftClaim(uint256 _tokenId) external {
        require(!claimed[_tokenId], "already claimed");
        require(PatronNFT(patronNFT).ownerOf(_tokenId) == msg.sender, "not owner of Patron NFT");

        claimed[_tokenId] = true;

        uint256 tokenData = PatronNFT(patronNFT).tokenData(_tokenId);
        uint256 amount = getClaimableFlux(tokenData);

        balanceOf[msg.sender] += amount;
    }
}

/// @notice Deploys the reduced system, claims FLUX for one patron NFT, and
///         proves the claimant receives strictly less FLUX than the
///         mathematically-equivalent, round-trip-free formula would produce.
contract Exploit {
    MockVeALCX public ve;
    PatronNFT public nft;
    FluxToken public flux;

    uint256 public constant TOKEN_ID = 1;
    // Same order of magnitude as the original PoC (10 ether input amount).
    uint256 public constant TOKEN_DATA = 10 ether;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant VE_MUL = 2;
    uint256 internal constant VE_MAX = 365 days;
    uint256 internal constant FLUX_PER_VE = 5000;
    uint256 internal constant FLUX_MUL = 4;
    uint256 internal constant BPT_MULTIPLIER = 40;

    constructor() {
        ve = new MockVeALCX();
        nft = new PatronNFT();
        flux = new FluxToken(address(ve), address(nft));

        nft.mint(address(this), TOKEN_ID, TOKEN_DATA);
    }

    function run() external {
        flux.nftClaim(TOKEN_ID);
        uint256 actualFlux = flux.balanceOf(address(this));

        // The amount the mathematically-equivalent, round-trip-free formula
        // (the finding's suggested fix) would have produced for the SAME bpt.
        uint256 bpt = (TOKEN_DATA * BPT_MULTIPLIER) / BPS;
        uint256 expectedFlux = (bpt * VE_MUL * (FLUX_PER_VE + BPS)) / BPS / FLUX_MUL;

        // HARM: the claimant permanently receives strictly less FLUX than
        // they are owed — a real, unrecoverable dust loss on every single
        // claim, caused entirely by the redundant div/mul round-trip.
        require(actualFlux < expectedFlux, "harm not demonstrated: dust loss must occur");
        uint256 dustLost = expectedFlux - actualFlux;
        require(dustLost > 0, "harm not demonstrated: dust amount must be nonzero");
    }
}
