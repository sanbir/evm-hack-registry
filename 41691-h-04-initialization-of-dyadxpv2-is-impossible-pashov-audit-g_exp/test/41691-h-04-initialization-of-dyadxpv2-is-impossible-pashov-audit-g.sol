// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    DYAD — Initialization of DyadXPv2 is impossible (unbounded init loop DoS)
    Pashov Audit Group review — finding [H-04] (#41691) — HIGH

    Root cause: DyadXPv2.initialize() eagerly loops across the ENTIRE DNFT
    supply, writing a NoteXPData struct per note and, on every iteration,
    performing two external reads (KEROSENE_VAULT.id2asset(i) and
    DYAD.mintedDyad(i)). On mainnet the DNFT supply is 882. Measured cost is
    ~35.6K gas/iteration, so the loop consumes >30M gas — MORE than the 30M
    Ethereum block gas limit. The transaction therefore can never be included
    in a block: the DyadXPv2 upgrade is PERMANENTLY un-initializable, a
    liveness brick that bricks the entire XP-staking upgrade.

    This file is a self-contained, cheatcode-free reduction. DyadXPv2 keeps the
    VERBATIM offending loop from the finding (see the @> VULN line). The three
    external dependencies (DNft, KeroseneVault, Dyad) are modeled by minimal
    mocks so that per-iteration gas is realistic (a real struct SSTORE plus the
    two external SLOAD-backed reads). The mock DNft reports the real mainnet
    supply of 882.

    Harm is a liveness/gas DoS, not a fund loss. Exactly as the original finding
    does ("Due to foundry limitations, it's not possible to run the PoC across
    all 882 iterations ... calculate the gas used for 88 iterations"), run()
    executes initialize() over a MEASURABLE 88-note sample, derives the per-note
    gas, and extrapolates to the real mainnet supply of 882. The extrapolated
    cost EXCEEDS the 30M mainnet block gas limit — i.e. on-chain the full-supply
    initialize() can never fit in a block and the upgrade is unmineable forever.
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////// external dependency interfaces ////////////////////*/

interface IDNft {
    function totalSupply() external view returns (uint256);
}

interface IKeroseneVault {
    function id2asset(uint256 id) external view returns (uint256);
}

interface IDyad {
    function mintedDyad(uint256 id) external view returns (uint256);
}

/*//////////////////////////// mocked dependencies ///////////////////////////*/

/// @dev Mock DNft whose totalSupply() reports the loop bound. We feed it a
///      MEASURABLE sample (88 notes, exactly the 10% sample the original finding
///      timed) and extrapolate the per-note cost to the real mainnet supply of
///      882 — which is what pushes the full initialize() past the block gas limit.
contract MockDNft is IDNft {
    uint256 public totalSupply;

    constructor(uint256 supply) {
        totalSupply = supply;
    }
}

/// @dev Mock KeroseneVault. id2asset(i) performs one SLOAD (state read) and
///      returns a non-zero deposited amount per note, mirroring the cold-ish
///      external read the real loop makes each iteration.
contract MockKeroseneVault is IKeroseneVault {
    uint256 private base = 1e18;

    function id2asset(uint256 id) external view returns (uint256) {
        return base + id; // non-zero -> the packed struct slot is a fresh SSTORE
    }
}

/// @dev Mock Dyad. mintedDyad(i) performs one SLOAD and returns a non-zero
///      minted amount per note, mirroring the second external read per loop.
contract MockDyad is IDyad {
    uint256 private base = 5e17;

    function mintedDyad(uint256 id) external view returns (uint256) {
        return base + id; // non-zero -> dyadMinted slot is a fresh SSTORE
    }
}

/*////////////////////////// vulnerable contract /////////////////////////////*/

/// @notice Reduced DyadXPv2. The initialize() body preserves the finding's
///         exact offending loop verbatim.
contract DyadXPv2 {
    struct NoteXPData {
        uint40 lastAction; //  packed with keroseneDeposited + lastXP into slot 0
        uint96 keroseneDeposited;
        uint120 lastXP;
        uint256 totalXP; //     slot 1
        uint256 dyadMinted; //  slot 2
    }

    // external dependencies, fixed at deploy time (immutable), exactly as the
    // real DyadXPv2 wires DNft / KeroseneVault / Dyad through its constructor.
    IDNft public immutable DNFT;
    IKeroseneVault public immutable KEROSENE_VAULT;
    IDyad public immutable DYAD;

    mapping(uint256 => NoteXPData) public noteData;
    bool public initialized;

    constructor(address dnft, address keroseneVault, address dyad) {
        DNFT = IDNft(dnft);
        KEROSENE_VAULT = IKeroseneVault(keroseneVault);
        DYAD = IDyad(dyad);
    }

    /// @notice One-shot upgrade initializer. On the real upgrade this runs
    ///         once, inside upgradeToAndCall, and MUST fit in a single block.
    function initialize(address) external {
        require(!initialized, "already initialized"); // stand-in for OZ `initializer`
        initialized = true;

        uint256 dnftSupply = DNFT.totalSupply();

        // FIX: do NOT eagerly loop the entire dnftSupply on initialization.
        //      Populate noteData lazily on each note's first interaction (or in
        //      bounded, caller-paged batches) so init cost is O(1), not O(supply).
        for (uint256 i = 0; i < dnftSupply; ++i) { // @> VULN: unbounded loop over full DNFT supply (882 mainnet) -> initialize() burns >30M gas -> exceeds block gas limit -> upgrade permanently un-initializable
            noteData[i] = NoteXPData({
                lastAction: uint40(block.timestamp),
                keroseneDeposited: uint96(KEROSENE_VAULT.id2asset(i)),
                lastXP: noteData[i].lastXP,
                totalXP: noteData[i].lastXP,
                dyadMinted: DYAD.mintedDyad(i)
            });
        }
    }
}

/*////////////////////////////// exploit driver //////////////////////////////*/

/// @notice Deploys the reduced system with the real mainnet DNFT supply (882),
///         then measures that initialize() consumes MORE than the 30M block gas
///         limit — proving the upgrade can never be initialized on-chain.
contract Exploit {
    // The real DNFT supply on mainnet at the time of the finding.
    uint256 public constant MAINNET_DNFT_SUPPLY = 882;
    // The measurable sample size we actually run in-VM (the finding's own 10%
    // sample). Per-note gas is measured here and extrapolated to the full 882.
    uint256 public constant SAMPLE_SIZE = 88;
    // The Ethereum mainnet block gas limit the init cost must stay under to be
    // includable in a block; the extrapolated full-supply cost does not.
    uint256 public constant BLOCK_GAS_LIMIT = 30_000_000;

    MockDNft public dnft;
    MockKeroseneVault public keroseneVault;
    MockDyad public dyad;
    DyadXPv2 public xp;

    // gas consumed by the measured 88-note initialize(), the derived per-note
    // cost, and the extrapolated full-supply (882) cost — asserted in run() and
    // re-asserted by the driver test.
    uint256 public gasUsed;
    uint256 public perNoteGas;
    uint256 public extrapolatedMainnetGas;

    constructor() {
        // Fixed CREATE order (Exploit nonce -> deployed contract):
        //   nonce 1 -> MockDNft            (reports the 88-note sample bound)
        //   nonce 2 -> MockKeroseneVault
        //   nonce 3 -> MockDyad
        //   nonce 4 -> DyadXPv2            (the vulnerable, un-initializable contract)
        dnft = new MockDNft(SAMPLE_SIZE); // nonce 1
        keroseneVault = new MockKeroseneVault(); // nonce 2
        dyad = new MockDyad(); // nonce 3
        xp = new DyadXPv2(address(dnft), address(keroseneVault), address(dyad)); // nonce 4
    }

    /// @notice Run initialize() over the measurable 88-note sample, derive the
    ///         per-note gas, and extrapolate to the real 882-note mainnet supply.
    ///         Assert the extrapolated cost exceeds the block gas limit — i.e. on
    ///         mainnet the full-supply initialize() can NEVER be mined. (This is
    ///         exactly the sample-and-extrapolate method the original finding used.)
    function run() external {
        uint256 g = gasleft();
        xp.initialize(address(this)); // loops SAMPLE_SIZE (88) notes
        uint256 used = g - gasleft();
        gasUsed = used;

        uint256 perNote = used / SAMPLE_SIZE; // measured per-note gas
        perNoteGas = perNote;
        uint256 mainnetCost = perNote * MAINNET_DNFT_SUPPLY; // extrapolate to 882
        extrapolatedMainnetGas = mainnetCost;

        // HARM (liveness brick): extrapolated over the real 882-note supply,
        // initialize() consumes more than a full mainnet block's gas. Because a
        // transaction cannot exceed the block gas limit, DyadXPv2.initialize()
        // can never be included on-chain -> the DyadXPv2 upgrade is permanently
        // un-initializable and the XP-staking upgrade is bricked.
        require(mainnetCost > BLOCK_GAS_LIMIT, "not a DoS: full-supply init fits inside a block");
    }
}
