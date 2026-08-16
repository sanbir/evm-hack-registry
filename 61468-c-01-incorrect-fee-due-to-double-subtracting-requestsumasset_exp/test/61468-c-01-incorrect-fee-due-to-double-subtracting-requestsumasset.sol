// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Blueberry HyperEvmVault finding
// 61468 (C-01): "Incorrect fee due to double subtracting `requestSum.assets`".
//
// Real audited source (both vulnerable functions are reproduced VERBATIM from
// the report snippet; the vulnerable line is marked @>):
//   report   github.com/pashov/audits/blob/master/team/md/Blueberry-security-review_2025-03-26.md
//   contract HyperEvmVault
//   fns      _calculateFee (the @> line) and _totalEscrowValue (the upstream
//            subtraction that makes @> a *double* subtraction)
//
// Root cause: `_calculateFee(grossAssets)` computes
//     eligibleForFeeTake = grossAssets - $.requestSum.assets;   // @>
// but `grossAssets` is passed straight from `_totalEscrowValue`, which ALREADY
// returned `assets_ - $.requestSum.assets`. So the pending-redemption amount is
// subtracted TWICE: the management fee is levied on `totalTvl - 2*requestSum`
// instead of `totalTvl - requestSum`. The vault's fee recipient is therefore
// shorted a fee on exactly `requestSum.assets` worth of value every collection
// (and, when `requestSum.assets` exceeds the already-reduced grossAssets, the
// subtraction underflows and reverts — a fee-collection DoS).
//
// The two arithmetic bodies are byte-for-byte the report snippet. Everything the
// vulnerable path touches (the per-escrow `tvl()`, the L1-block gate, the
// `requestSum`/fee-config storage, the `_totalEscrowValue -> _calculateFee` call
// chain) is a faithful minimal double with real accounting — the double
// subtraction emerges from the verbatim code, it is not asserted. The harm is
// the concrete fee shortfall (correct fee minus the buggy fee), computed from
// the corrected formula the finding recommends and minted to the SINK marker
// address as the magnitude of value the protocol fails to collect.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 double for the vault's underlying asset. Also
///      serves as the marker token: the fee shortfall (protocol's loss) is
///      minted to SINK on this token as the harm magnitude.
contract MiniToken {
    string public name = "Blueberry Vault Asset";
    string public symbol = "USD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Faithful double of a Blueberry `VaultEscrow`. `_totalEscrowValue` sums
///      `escrow.tvl()` across every escrow; each escrow reports the assets it
///      currently holds on the vault's behalf. Real accounting: `tvl()` returns
///      the escrow's actual recorded balance.
contract VaultEscrow {
    uint256 internal _tvl;

    constructor(uint256 tvl_) {
        _tvl = tvl_;
    }

    function tvl() external view returns (uint256) {
        return _tvl;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `_totalEscrowValue` and `_calculateFee` are reproduced
// VERBATIM from the audited HyperEvmVault (report snippet). `previewFee()` wires
// them together exactly as the finding describes ("grossAssets is passed
// directly from _totalEscrowValue"), so the second subtraction on the @> line is
// applied on an already-reduced value.
// ─────────────────────────────────────────────────────────────────────────────
contract HyperEvmVault {
    struct RequestSum {
        uint256 shares;
        uint256 assets;
    }

    struct V1Storage {
        address[] escrows;
        uint256 lastL1Block;
        uint256 currentBlockDeposits;
        RequestSum requestSum;
        uint256 lastFeeCollectionTimestamp;
        uint256 managementFeeBps;
    }

    // Blueberry fee-math constants (values as in the audited contract).
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant ONE_YEAR = 365 days;

    V1Storage internal _v1;

    // Faithful stand-in for the HyperEVM L1 block number (a precompile in the
    // real contract). Left distinct from `lastL1Block` unless configured equal.
    uint256 internal _l1Block;

    MiniToken public asset;

    constructor(MiniToken asset_) {
        asset = asset_;
    }

    function _getV1Storage() internal view returns (V1Storage storage $) {
        $ = _v1;
    }

    function l1Block() public view returns (uint256) {
        return _l1Block;
    }

    // ── VULNERABLE functions — bodies VERBATIM from the report snippet ──

    function _totalEscrowValue(V1Storage storage $) internal view returns (uint256 assets_) {
        uint256 escrowLength = $.escrows.length;
        for (uint256 i = 0; i < escrowLength; ++i) {
            VaultEscrow escrow = VaultEscrow($.escrows[i]);
            assets_ += escrow.tvl();
        }

        if ($.lastL1Block == l1Block()) {
            assets_ += $.currentBlockDeposits;
        }

        return assets_ - $.requestSum.assets;
    }

    function _calculateFee(V1Storage storage $, uint256 grossAssets) internal view returns (uint256 feeAmount_) {
        if (grossAssets == 0 || block.timestamp <= $.lastFeeCollectionTimestamp) {
            return 0;
        }

        // Calculate time elapsed since last fee collection
        uint256 timeElapsed = block.timestamp - $.lastFeeCollectionTimestamp;

        // We subtract the pending redemption requests from the total asset value to avoid taking more fees than needed from
        //    users who do not have any pending redemption requests
        uint256 eligibleForFeeTake = grossAssets - $.requestSum.assets; // @> VULN: `grossAssets` already had `$.requestSum.assets` subtracted in `_totalEscrowValue`, so this subtracts it a SECOND time -> fee undercharged (or underflow/revert)
        // Calculate the pro-rated management fee based on time elapsed
        feeAmount_ = eligibleForFeeTake * $.managementFeeBps * timeElapsed / BPS_DENOMINATOR / ONE_YEAR;

        return feeAmount_;
    }

    // ── faithful call chain + read-only views exercising the verbatim math ──

    /// @notice The value the finding calls `grossAssets`: `_totalEscrowValue`
    ///         (which already subtracts `requestSum.assets` once).
    function totalEscrowValue() external view returns (uint256) {
        V1Storage storage $ = _getV1Storage();
        return _totalEscrowValue($);
    }

    /// @notice The exact call the finding flags: fee is computed on the value
    ///         returned by `_totalEscrowValue`, so the marked subtraction is the
    ///         second one.
    function previewFee() external view returns (uint256) {
        V1Storage storage $ = _getV1Storage();
        return _calculateFee($, _totalEscrowValue($));
    }

    // ── faithful harness config (models deposit / requestRedeem / fee setup) ──

    function addEscrow(address escrow_) external {
        _v1.escrows.push(escrow_);
    }

    function setRequestSumAssets(uint256 assets_) external {
        _v1.requestSum.assets = assets_;
    }

    function setManagementFeeBps(uint256 bps_) external {
        _v1.managementFeeBps = bps_;
    }

    function setLastFeeCollectionTimestamp(uint256 ts_) external {
        _v1.lastFeeCollectionTimestamp = ts_;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: configure a vault whose TVL is 1000e18 with 400e18 of pending
// redemptions and a 2% annual management fee over one year, then prove the
// verbatim `_calculateFee(_totalEscrowValue())` chain undercharges the fee by a
// full fee on the 400e18 pending amount (the double-subtracted value). The
// shortfall is minted to SINK as the magnitude of fee the protocol fails to
// collect.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public token; // child nonce 1 (marker / profit token; SINK credited here)
    HyperEvmVault public vault; // child nonce 2 (VULN)
    VaultEscrow public escrow; // child nonce 3

    // Silent-harm SINK marker (per authoring convention for accounting/DoS harms)
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 public grossAssetsValue; // _totalEscrowValue() = TOTAL_TVL - PENDING
    uint256 public feeBuggy; // fee from the verbatim double-subtracting chain
    uint256 public feeCorrect; // fee under the recommended single-subtraction fix
    uint256 public shortfall; // feeCorrect - feeBuggy (fee the protocol loses)

    uint256 internal constant TOTAL_TVL = 1000e18; // vault TVL held across escrows
    uint256 internal constant PENDING = 400e18; // requestSum.assets (pending redemptions)
    uint256 internal constant FEE_BPS = 200; // 2% annual management fee

    constructor() {
        token = new MiniToken(); // nonce 1
        vault = new HyperEvmVault(token); // nonce 2 (VULN)
        escrow = new VaultEscrow(TOTAL_TVL); // nonce 3
    }

    function run() external {
        // Configure the vault faithfully: one escrow holding the full TVL, a
        // pending-redemption sum of 400e18, a 2% fee, and a last-collection
        // timestamp exactly ONE_YEAR in the past (timeElapsed == ONE_YEAR).
        vault.addEscrow(address(escrow));
        vault.setRequestSumAssets(PENDING);
        vault.setManagementFeeBps(FEE_BPS);
        vault.setLastFeeCollectionTimestamp(block.timestamp - vault.ONE_YEAR());

        uint256 timeElapsed = vault.ONE_YEAR();
        uint256 bps = vault.BPS_DENOMINATOR();
        uint256 year = vault.ONE_YEAR();

        // grossAssets = _totalEscrowValue() = 1000e18 - 400e18 = 600e18
        grossAssetsValue = vault.totalEscrowValue();

        // Buggy fee from the verbatim chain: eligibleForFeeTake = 600e18 - 400e18
        //   = 200e18 -> fee = 200e18 * 2% = 4e18
        feeBuggy = vault.previewFee();

        // Corrected fee (finding's recommendation: do NOT subtract requestSum
        //   again) -> eligibleForFeeTake == grossAssets = 600e18 -> fee = 12e18
        feeCorrect = grossAssetsValue * FEE_BPS * timeElapsed / bps / year;

        shortfall = feeCorrect - feeBuggy;

        // Mint the under-collected fee to SINK as the harm magnitude.
        token.mint(SINK, shortfall);

        // HARM: the verbatim double subtraction undercharges the management fee
        // by a full fee on the entire pending-redemption amount (400e18), i.e.
        // the protocol's fee recipient is silently shorted 8e18 every collection.
        require(feeBuggy < feeCorrect, "fee not undercollected");
        require(
            shortfall == PENDING * FEE_BPS * timeElapsed / bps / year,
            "shortfall != double-subtracted fee amount"
        );
        require(token.balanceOf(SINK) == shortfall, "sink not credited harm magnitude");
    }
}
