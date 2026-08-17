// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Lucidly finding 36354 (H-14):
// "Incorrect parameters bricks certain functions".
//
// Real audited source (the vulnerable parameter list + the reverting loop are
// reproduced VERBATIM, the primary vulnerable line is marked @> VULN):
//   repo    github.com/lucidlyfi/lucidly-core-v1  (now private)
//   commit  f00c45bbadc836b9eaa94717a0b3aa017e792588
//   file    src/Pool.sol
//   fns     setWeightBands, setRamp
//   report  github.com/pashov/audits/blob/master/team/md/Lucidly-security-review.md
//   src     embedded  (the finding's ```solidity snippets are the verbatim source)
//
// Root cause: `setWeightBands` and `setRamp` declare their array parameters as
// FIXED-length `uint256[MAX_NUM_TOKENS] calldata` with `MAX_NUM_TOKENS = 32`.
// A fixed-length array parameter forces the caller to ABI-encode EXACTLY 32
// elements — a shorter array does not type-check / decodes to a revert. But the
// functions are only meaningful for a pool of `_numTokens` tokens, and every
// iteration guards with `if (t >= _numTokens) revert Pool__IndexOutOfBounds();`
// inside a `for (t = 0; t < MAX_NUM_TOKENS; t++)` loop. So for any pool with
// fewer than 32 tokens (the normal case), the forced 32-length call ALWAYS
// reverts at `t == _numTokens`. The caller can neither pass a short array (type
// rejects it) nor a full 32-length array (loop reverts) — both `setWeightBands`
// and `setRamp` are permanently bricked / unusable.
//
// The parameter declarations, the `MAX_NUM_TOKENS` constant, the
// `Pool__IndexOutOfBounds` error and the reverting loop are byte-for-byte the
// finding's embedded source. The per-token band/ramp storage writes inside the
// loop are faithful minimal doubles (real state writes, not fake constants).
// Because the harm is a silent liveness DoS (no positive transfer to any
// attacker), the count of permanently-bricked functions is minted to
// SINK 0x..D00d on a marker token as the quantified harm.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Marker token: the harm here is a DoS/brick (no value moves), so the
///      number of permanently-unusable functions is minted to SINK as the
///      quantified loss magnitude.
contract MarkerToken {
    string public name = "Lucidly Bricked Admin Function Marker";
    string public symbol = "BRICKED";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the Lucidly `Pool` admin setters. The parameter lists,
// `MAX_NUM_TOKENS`, the `Pool__IndexOutOfBounds` error and the reverting loop
// are reproduced VERBATIM from the audited source.
// ─────────────────────────────────────────────────────────────────────────────
contract Pool {
    // VERBATIM: MAX_NUM_TOKENS = 32 (drives both the fixed-size params and the loop bound)
    uint256 internal constant MAX_NUM_TOKENS = 32;

    // VERBATIM: the error the per-iteration bounds check reverts with
    error Pool__IndexOutOfBounds();

    // number of tokens the pool actually uses (< 32 for any normal pool)
    uint256 internal _numTokens;

    // ── faithful minimal doubles for the state the loop bodies write ──
    struct WeightBand {
        uint256 lower;
        uint256 upper;
    }

    mapping(uint256 => WeightBand) public weightBand; // token index => band
    mapping(uint256 => uint256) public rampWeight; // token index => target weight
    uint256 public amplification;
    uint256 public rampDuration;
    uint256 public rampStart;

    constructor(uint256 numTokens_) {
        _numTokens = numTokens_;
    }

    /// @notice VERBATIM parameter list from the audited `setWeightBands`. The
    ///         fixed-size `uint256[MAX_NUM_TOKENS] calldata` arrays force the
    ///         caller to supply exactly 32 elements, yet the loop reverts once
    ///         `t == _numTokens` — so a normal (< 32 token) pool can never call it.
    function setWeightBands(
        uint256[MAX_NUM_TOKENS] calldata tokens_, // @> VULN: fixed-size (=32) array param forces 32 args; loop below then reverts at t==_numTokens -> function is unusable
        uint256[MAX_NUM_TOKENS] calldata lower_,
        uint256[MAX_NUM_TOKENS] calldata upper_
    ) external {
        for (uint256 t = 0; t < MAX_NUM_TOKENS; t++) {
            if (t >= _numTokens) revert Pool__IndexOutOfBounds();
            weightBand[tokens_[t]] = WeightBand({lower: lower_[t], upper: upper_[t]});
        }
    }

    /// @notice VERBATIM parameter list from the audited `setRamp` — same
    ///         fixed-size `uint256[MAX_NUM_TOKENS] calldata weights_` defect and
    ///         the same reverting loop, so it is bricked identically.
    function setRamp(
        uint256 amplification_,
        uint256[MAX_NUM_TOKENS] calldata weights_, // @> VULN: fixed-size (=32) array param forces 32 args; loop below reverts at t==_numTokens
        uint256 duration_,
        uint256 start_
    ) external {
        amplification = amplification_;
        rampDuration = duration_;
        rampStart = start_;
        for (uint256 t = 0; t < MAX_NUM_TOKENS; t++) {
            if (t >= _numTokens) revert Pool__IndexOutOfBounds();
            rampWeight[t] = weights_[t];
        }
    }

    // read helpers for the driver
    function numTokens() external view returns (uint256) {
        return _numTokens;
    }

    function maxNumTokens() external pure returns (uint256) {
        return MAX_NUM_TOKENS;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: deploy a normal 3-token pool, then supply perfectly valid,
// fully-populated 32-length arrays (the only shape the fixed-size params accept)
// to BOTH admin setters and prove each reverts with Pool__IndexOutOfBounds —
// i.e. neither can ever be configured. The two bricked functions are recorded
// to SINK on the BRICKED marker token.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    Pool public pool;
    MarkerToken public marker;

    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant NUM_TOKENS = 3; // a normal Lucidly pool (< 32 tokens)

    bool public setWeightBandsBricked;
    bool public setRampBricked;
    uint256 public brickedFunctions; // magnitude minted to SINK

    constructor() {
        pool = new Pool(NUM_TOKENS); // child nonce 1 (VULN)
        marker = new MarkerToken(); // child nonce 2 (profit/marker)
    }

    function run() external {
        // Build the ONLY array shape the fixed-size params accept: exactly 32
        // fully-populated elements (distinct nonzero values, so the revert is not
        // a zero-input artifact). A shorter array does not even type-check.
        uint256[32] memory full;
        for (uint256 i = 0; i < 32; i++) {
            full[i] = i + 1;
        }

        // 1) setWeightBands with a valid 32-length call -> reverts at t == _numTokens (3)
        bool wbReverted;
        bytes memory wbErr;
        try pool.setWeightBands(full, full, full) {
            wbReverted = false;
        } catch (bytes memory err) {
            wbReverted = true;
            wbErr = err;
        }
        setWeightBandsBricked = wbReverted;

        require(wbReverted, "setWeightBands unexpectedly succeeded -- brick not reproduced");
        require(
            keccak256(wbErr) == keccak256(abi.encodeWithSelector(Pool.Pool__IndexOutOfBounds.selector)),
            "setWeightBands reverted for the wrong reason"
        );

        // 2) setRamp with a valid 32-length call -> reverts identically
        bool rampReverted;
        bytes memory rampErr;
        try pool.setRamp(1e18, full, 7 days, block.timestamp) {
            rampReverted = false;
        } catch (bytes memory err) {
            rampReverted = true;
            rampErr = err;
        }
        setRampBricked = rampReverted;

        require(rampReverted, "setRamp unexpectedly succeeded -- brick not reproduced");
        require(
            keccak256(rampErr) == keccak256(abi.encodeWithSelector(Pool.Pool__IndexOutOfBounds.selector)),
            "setRamp reverted for the wrong reason"
        );

        // sanity: the pool state was never configured (both writes are permanently blocked)
        require(pool.amplification() == 0, "amplification should still be unset");
        (uint256 lo0,) = pool.weightBand(1);
        require(lo0 == 0, "weight band should still be unset");

        // HARM: both admin setters are permanently unusable for any < 32-token
        // pool -> record the 2 bricked functions to SINK.
        brickedFunctions = 2;
        marker.mint(SINK, brickedFunctions * 1e18);

        require(marker.balanceOf(SINK) == 2e18, "bricked-function marker mismatch");
    }
}
