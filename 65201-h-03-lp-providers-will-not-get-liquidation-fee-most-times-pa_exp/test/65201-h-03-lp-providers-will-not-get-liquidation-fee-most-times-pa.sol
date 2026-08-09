// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Ostium finding 65201 (H-03):
// "LP providers will not get liquidation fee most times".
//
// When a position is liquidated, the trading layer routes the liquidation fee to
// the LP vault via `OstiumVault.receiveAssets(fee, trader)`. `receiveAssets`
// applies the incoming money to `accPnlPerToken` (as a reduction of traders'
// collective PnL) and never touches `accRewardsPerToken`, nor does it update the
// share price. The share-price formula `updateShareToAssetsPrice()` CLAMPS the
// negative part of the effective trader PnL to zero:
//
//     shareToAssetsPrice = (accRewardsPerToken + 1e18)
//                          - accPnlPerTokenThreshold
//                          - max(0, accPnlPerTokenUsed - accPnlPerTokenThreshold)
//
// So whenever the vault's net trader PnL is negative (traders in loss / vault
// over-collateralized), pushing `accPnlPerToken` further negative via
// `receiveAssets` changes NOTHING about the LP share price — even after the next
// settlement snapshots `accPnlPerTokenUsed = accPnlPerToken` and recomputes the
// price. The liquidation fee enters the vault's USDC balance but the LPs'
// redeemable value never rises: the reward they are owed is stuck/unclaimable.
//
// The auditor's recommended fix is to route the fee through `distributeReward()`,
// which credits `accRewardsPerToken` and immediately updates the share price —
// so the LPs actually receive it. That fix is our negative control
// (`OstiumVaultFixed`).
//
// VERBATIM inlined from 0xOstium/smart-contracts-public @ 8390ce4
//   src/OstiumVault.sol:
//     L22   PRECISION_18
//     L265-267 maxAccPnlPerToken()
//     L271-273 effectiveAccPnlPerTokenUsed()
//     L359-365 updateShareToAssetsPrice()   (the negative clamp)
//     L721-729 distributeReward()           (reward path — the fix)
//     L757-772 receiveAssets()              (the buggy liquidation-fee path)
//     L790-791 settlement snapshot core (accPnlPerTokenUsed = accPnlPerToken; updateShareToAssetsPrice())
//     L138 shareToAssetsPrice = PRECISION_18 (init)
//     L379-383 _convertToAssets() core (LP claimable value)
// Only the opaque out-of-scope async-settlement machinery (openPnl oracle,
// deposit/withdraw execution, daily-delta time gate) is dropped as noise — it
// does not cure the negative clamp, which is the durable issue #2.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 interface (the vault's underlying asset boundary).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Minimal faithful double for OpenZeppelin's SafeERC20 (bool-checked).
library SafeERC20 {
    function safeTransferFrom(IERC20 t, address from, address to, uint256 a) internal {
        require(t.transferFrom(from, to, a), "safeTransferFrom failed");
    }

    function safeTransfer(IERC20 t, address to, uint256 a) internal {
        require(t.transfer(to, a), "safeTransfer failed");
    }
}

/// @dev Minimal faithful double for OpenZeppelin's SafeCast (uint256 -> int256).
library SafeCast {
    function toInt256(uint256 v) internal pure returns (int256) {
        require(v <= uint256(type(int256).max), "SafeCast: overflow");
        return int256(v);
    }
}

/// @dev Minimal ERC20 double. Used both as the vault's USDC asset (6 decimals)
///      and as the LOCKED-USDC marker token that records the denied LP reward.
contract MiniToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: liquidation fee routed through `receiveAssets`.
// State + accounting inlined verbatim from OstiumVault. A minimal share ledger
// replaces the ERC4626Upgradeable base (only totalSupply + a per-holder balance
// are needed to price shares).
// ─────────────────────────────────────────────────────────────────────────────
contract OstiumVault {
    using SafeCast for uint256;

    uint64 constant PRECISION_18 = 1e18; // 18 decimals   (verbatim L22)

    // ---- share-accounting state (verbatim field set) ----
    uint256 public shareToAssetsPrice; //          (L50)
    uint256 public accRewardsPerToken; //          (L51)
    int256 public accPnlPerToken; //               (L57)
    int256 public accPnlPerTokenUsed; //           (L58, snapshot of accPnlPerToken)
    int256 public dailyAccPnlDeltaPerToken; //     (L59)
    int256 public totalClosedPnl; //               (L62)
    int256 public accPnlPerTokenThreshold; //      (L101, >= 0 invariant)

    // ---- minimal share ledger standing in for ERC4626Upgradeable ----
    address public assetToken;
    uint256 internal _supply;
    mapping(address => uint256) public shareBalance;

    event ShareToAssetsPriceUpdated(uint256 price);
    event AssetsReceived(address sender, address user, uint256 assets);
    event RewardDistributed(address sender, uint256 assets, uint256 accRewardsPerToken);

    constructor(address _asset) {
        assetToken = _asset;
        shareToAssetsPrice = PRECISION_18; // verbatim L138
    }

    function totalSupply() public view returns (uint256) {
        return _supply;
    }

    function _assetIERC20() private view returns (IERC20) {
        return IERC20(assetToken); // core of L367-369
    }

    // ---- test harness setup (NOT part of the vulnerable path) ----
    function mintShares(address to, uint256 shares) external {
        shareBalance[to] += shares;
        _supply += shares;
    }

    function seedState(int256 _accPnlPerToken, int256 _accPnlPerTokenUsed, uint256 _accRewardsPerToken, int256 _threshold)
        external
    {
        accPnlPerToken = _accPnlPerToken;
        accPnlPerTokenUsed = _accPnlPerTokenUsed;
        accRewardsPerToken = _accRewardsPerToken;
        accPnlPerTokenThreshold = _threshold;
        updateShareToAssetsPrice();
    }

    // ═══════════════════════ VERBATIM OstiumVault logic ═══════════════════════

    function maxAccPnlPerToken() public view returns (uint256) {
        // verbatim L265-267
        return accRewardsPerToken + PRECISION_18;
    }

    function effectiveAccPnlPerTokenUsed() public view returns (int256) {
        // verbatim L271-273
        return accPnlPerTokenUsed - accPnlPerTokenThreshold;
    }

    function updateShareToAssetsPrice() private {
        // verbatim L359-365 — NEGATIVE CLAMP: the negative part of `effective`
        // (i.e. traders in loss) is discarded, so trader-loss buffer / liquidation
        // fees routed into accPnlPerToken never raise the LP share price.
        int256 effective = effectiveAccPnlPerTokenUsed();
        shareToAssetsPrice =
            maxAccPnlPerToken() - uint256(accPnlPerTokenThreshold) - (effective > 0 ? uint256(effective) : uint256(0));

        emit ShareToAssetsPriceUpdated(shareToAssetsPrice);
    }

    function distributeReward(uint256 assets) external {
        // verbatim L721-729 — credits accRewardsPerToken AND updates the price,
        // so LPs receive the reward regardless of trader PnL sign. This is the
        // path the auditor recommends for the liquidation fee.
        address sender = msg.sender;
        SafeERC20.safeTransferFrom(_assetIERC20(), sender, address(this), assets);

        accRewardsPerToken += assets * PRECISION_18 / totalSupply();
        updateShareToAssetsPrice();

        emit RewardDistributed(sender, assets, accRewardsPerToken);
    }

    function receiveAssets(uint256 assets, address user) external {
        // verbatim L757-772 (async-settlement triggers dropped as out-of-scope).
        address sender = msg.sender;
        SafeERC20.safeTransferFrom(_assetIERC20(), sender, address(this), assets);

        int256 accPnlDelta = (assets * PRECISION_18 / totalSupply()).toInt256();
        accPnlPerToken -= accPnlDelta; // @> liquidation fee sunk into accPnlPerToken (not accRewardsPerToken) with no share-price update; when trader net PnL is negative the clamp in updateShareToAssetsPrice() neutralizes it, so the LP share price never rises

        dailyAccPnlDeltaPerToken -= accPnlDelta;
        totalClosedPnl -= assets.toInt256();

        // [dropped: tryResetDailyAccPnlDelta(); tryNewSettlement();]
        emit AssetsReceived(sender, user, assets);
    }

    function settleSnapshot() external {
        // verbatim core of _updateAccPnlPerTokenUsed L790-791: the eventual
        // settlement DOES snapshot accPnlPerTokenUsed and recompute the price,
        // yet with net-negative trader PnL the clamp keeps the price flat — this
        // is the durable issue #2 (openPnl refresh omitted: it is 0 here).
        accPnlPerTokenUsed = accPnlPerToken;
        updateShareToAssetsPrice();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        // verbatim core L379-383 (floor mulDiv): LP claimable value in assets.
        return shares * shareToAssetsPrice / PRECISION_18;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED variant (negative control): the liquidation-fee entrypoint routes the
// fee through the reward path (the auditor's recommendation). Everything else is
// identical to OstiumVault.
// ─────────────────────────────────────────────────────────────────────────────
contract OstiumVaultFixed {
    using SafeCast for uint256;

    uint64 constant PRECISION_18 = 1e18;

    uint256 public shareToAssetsPrice;
    uint256 public accRewardsPerToken;
    int256 public accPnlPerToken;
    int256 public accPnlPerTokenUsed;
    int256 public dailyAccPnlDeltaPerToken;
    int256 public totalClosedPnl;
    int256 public accPnlPerTokenThreshold;

    address public assetToken;
    uint256 internal _supply;
    mapping(address => uint256) public shareBalance;

    event ShareToAssetsPriceUpdated(uint256 price);
    event RewardDistributed(address sender, uint256 assets, uint256 accRewardsPerToken);

    constructor(address _asset) {
        assetToken = _asset;
        shareToAssetsPrice = PRECISION_18;
    }

    function totalSupply() public view returns (uint256) {
        return _supply;
    }

    function _assetIERC20() private view returns (IERC20) {
        return IERC20(assetToken);
    }

    function mintShares(address to, uint256 shares) external {
        shareBalance[to] += shares;
        _supply += shares;
    }

    function seedState(int256 _accPnlPerToken, int256 _accPnlPerTokenUsed, uint256 _accRewardsPerToken, int256 _threshold)
        external
    {
        accPnlPerToken = _accPnlPerToken;
        accPnlPerTokenUsed = _accPnlPerTokenUsed;
        accRewardsPerToken = _accRewardsPerToken;
        accPnlPerTokenThreshold = _threshold;
        updateShareToAssetsPrice();
    }

    function maxAccPnlPerToken() public view returns (uint256) {
        return accRewardsPerToken + PRECISION_18;
    }

    function effectiveAccPnlPerTokenUsed() public view returns (int256) {
        return accPnlPerTokenUsed - accPnlPerTokenThreshold;
    }

    function updateShareToAssetsPrice() private {
        int256 effective = effectiveAccPnlPerTokenUsed();
        shareToAssetsPrice =
            maxAccPnlPerToken() - uint256(accPnlPerTokenThreshold) - (effective > 0 ? uint256(effective) : uint256(0));

        emit ShareToAssetsPriceUpdated(shareToAssetsPrice);
    }

    /// @notice FIX (auditor recommendation): route the liquidation fee through
    ///         the reward path so it raises the LP share price immediately.
    function receiveAssets(uint256 assets, address user) external {
        address sender = msg.sender;
        SafeERC20.safeTransferFrom(_assetIERC20(), sender, address(this), assets);

        accRewardsPerToken += assets * PRECISION_18 / totalSupply();
        updateShareToAssetsPrice();

        emit RewardDistributed(sender, assets, accRewardsPerToken);
        user; // silence unused-parameter warning (kept for signature parity)
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * shareToAssetsPrice / PRECISION_18;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: one LP holds all shares; the vault is in a net-negative trader
// state (traders in loss). A 3 USDC liquidation fee is routed via `receiveAssets`
// (buggy) vs the reward path (fixed). Buggy: LP claimable value unchanged while
// the fee is genuinely stuck in the vault. Fixed: LP claimable value rises by the
// full fee. The denied 3 USDC reward is recorded on a LOCKED-USDC marker at SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant LP = 0x0000000000000000000000000000000000000a11; // sole LP
    address internal constant TRADER = 0x0000000000000000000000000000000000000B0b; // liquidated trader

    uint256 internal constant SUPPLY = 1_000e6; // 1000 oLP shares (6-decimal)
    uint256 internal constant FEE = 3e6; // 3 USDC liquidation fee
    int256 internal constant SEED_PNL = -100e15; // net-negative trader PnL (traders in loss)

    // Exposed results (the driver asserts on these).
    uint256 public lpValueBuggyBefore;
    uint256 public lpValueBuggyAfter;
    uint256 public lpValueFixedBefore;
    uint256 public lpValueFixedAfter;
    uint256 public lpDeltaBuggy; // expected 0 (LP gets nothing)
    uint256 public lpDeltaFixed; // expected FEE (LP gets the reward)
    uint256 public feeStuck; // real USDC that entered the buggy vault
    uint256 public sinkMarkerBalance; // expected FEE (denied reward magnitude)

    address public vaultAddr;
    address public vaultFixedAddr;
    address public markerAddr;
    address public usdcAddr;

    function run() external payable {
        // --- deploy asset, both vaults, and the marker (fixed order) ---
        MiniToken usdc = new MiniToken("USD Coin", "USDC", 6); // nonce 1
        OstiumVault vault = new OstiumVault(address(usdc)); // nonce 2
        OstiumVaultFixed vaultFixed = new OstiumVaultFixed(address(usdc)); // nonce 3
        MiniToken marker = new MiniToken("Locked LP Reward", "LOCKED-USDC", 6); // nonce 4 (LAST)

        vaultAddr = address(vault);
        vaultFixedAddr = address(vaultFixed);
        markerAddr = address(marker);
        usdcAddr = address(usdc);

        // --- one LP holds all shares in each vault ---
        vault.mintShares(LP, SUPPLY);
        vaultFixed.mintShares(LP, SUPPLY);

        // --- seed a net-negative trader state (traders in loss, threshold 0) ---
        //     effectiveAccPnlPerTokenUsed() = SEED_PNL - 0 < 0 -> price clamped to 1e18
        vault.seedState(SEED_PNL, SEED_PNL, 0, 0);
        vaultFixed.seedState(SEED_PNL, SEED_PNL, 0, 0);

        // --- fund the fee sender (this contract) and approve both vaults ---
        usdc.mint(address(this), FEE * 2);
        usdc.approve(address(vault), FEE);
        usdc.approve(address(vaultFixed), FEE);

        // ===================== BUGGY PATH: fee via receiveAssets =====================
        lpValueBuggyBefore = vault.convertToAssets(SUPPLY);
        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        vault.receiveAssets(FEE, TRADER);
        vault.settleSnapshot(); // even after settlement snapshots the price, the clamp keeps it flat

        lpValueBuggyAfter = vault.convertToAssets(SUPPLY);
        feeStuck = usdc.balanceOf(address(vault)) - vaultUsdcBefore;
        lpDeltaBuggy = lpValueBuggyAfter - lpValueBuggyBefore;

        // ================= CONTROL (FIX): same fee via reward path =================
        lpValueFixedBefore = vaultFixed.convertToAssets(SUPPLY);
        vaultFixed.receiveAssets(FEE, TRADER);
        lpValueFixedAfter = vaultFixed.convertToAssets(SUPPLY);
        lpDeltaFixed = lpValueFixedAfter - lpValueFixedBefore;

        // ============================ ASSERT THE HARM ============================
        // The fee genuinely entered the vault (real USDC), yet LP value is flat.
        require(feeStuck == FEE, "fee must have entered the vault");
        require(lpDeltaBuggy == 0, "buggy: LP claimable value must be unchanged");
        // The fix pays the LP the full fee.
        require(lpDeltaFixed == FEE, "control: LP claimable value must rise by the fee");

        // Record the denied reward magnitude (what LPs should have received) at SINK.
        marker.mint(SINK, lpDeltaFixed - lpDeltaBuggy); // = FEE = 3 LOCKED-USDC
        sinkMarkerBalance = marker.balanceOf(SINK);
        require(sinkMarkerBalance == FEE, "marker must record the denied reward");
    }
}
