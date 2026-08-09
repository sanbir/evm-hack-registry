// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Remora Dynamic Tokens finding 63778:
// "Pending payouts when resolving an investor are lost because there is no
//  mechanism to claim the resolved payment".
//
// When an investor loses access to their account, ChildToken::resolveUser
// migrates balances, locks and — via DividendManager::_resolvePay — the pending
// dividend payout to a NEW address. _resolvePay settles the OLD holder's pending
// (via _claimPayout, which zeroes the holder's accounting and RETURNS the amount
// WITHOUT transferring) and records that amount into _resolvedPay[newAddress].
//
// The bug: NO function ever reads _resolvedPay. The external claimPayout() pays
// only the caller's OWN _claimPayout(msg.sender) and never consults _resolvedPay.
// So the migrated dividend tokens (already held by the contract) become
// permanently locked: newAddress can never claim them. Re-resolving a second old
// address to the same newAddress also OVERWRITES _resolvedPay[newAddress],
// destroying the previously-recorded amount.
//
// The Remora repo (remora-projects/remora-dynamic-tokens) is deleted/private, so
// per the AuditVault finding this reproduction inlines the VERBATIM vulnerable
// _resolvePay body from the finding and faithfully reconstructs the surrounding
// _claimPayout / claimPayout / _resolvedPay accounting it depends on.
// Cyfrin fix (commit 1a69894): the resolved payout was made claimable by the
// newAddress via ChildToken::claimPayout.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for OpenZeppelin's SafeCast.toUint128 (used
///      verbatim by the vulnerable line). Reverts on overflow, exactly as OZ.
library SafeCast {
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);

    function toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) {
            revert SafeCastOverflowedUintDowncast(128, value);
        }
        return uint128(value);
    }
}

/// @dev Minimal ERC20 double for the opaque dividend token (USDC) held by the
///      DividendManager, and for the harm MARKER token. Not the vulnerable
///      boundary — the vulnerable contract is the DividendManager itself.
contract MiniToken {
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
// VULNERABLE contract. _resolvePay is inlined VERBATIM from the finding; the
// surrounding _claimPayout / claimPayout / _resolvedPay accounting is the
// faithful reconstruction of the ERC-7201 namespaced HolderManagement storage it
// operates on.
// ─────────────────────────────────────────────────────────────────────────────
contract DividendManager {
    event PaymentResolved(address indexed oldAddress, address indexed newAddress);

    /// @custom:storage-location erc7201:remora.storage.HolderManagement
    struct HolderManagementStorage {
        mapping(address => uint128) _resolvedPay; // migrated payout, keyed by newAddress
        mapping(address => uint256) pending;      // each holder's own accrued payout
    }

    HolderManagementStorage private _hms;

    MiniToken public dividendToken;

    constructor(address _dividendToken) {
        dividendToken = MiniToken(_dividendToken);
    }

    function _getHolderManagementStorage() private view returns (HolderManagementStorage storage) {
        return _hms;
    }

    /// @notice Settles `holder`'s own accrued payout and returns the amount.
    ///         It does NOT transfer — the caller decides where the tokens go.
    function _claimPayout(address holder) internal returns (uint256) {
        HolderManagementStorage storage $ = _getHolderManagementStorage();
        uint256 amount = $.pending[holder];
        $.pending[holder] = 0;
        return amount;
    }

    // ── VERBATIM vulnerable function from the finding ──────────────────────────
    function _resolvePay(address oldAddress, address newAddress) internal {
        _getHolderManagementStorage()._resolvedPay[newAddress] = SafeCast.toUint128(_claimPayout(oldAddress)); // @> migrates payout into _resolvedPay[newAddress], but NO function ever reads it -> funds locked; also overwrites any prior value
        emit PaymentResolved(oldAddress, newAddress);
    }
    // ───────────────────────────────────────────────────────────────────────────

    /// @notice ChildToken::resolveUser -> DividendManager::_resolvePay entry point.
    function resolveUser(address oldAddress, address newAddress) external {
        _resolvePay(oldAddress, newAddress);
    }

    /// @notice The ONLY payout claim path. It pays the caller's own settled
    ///         payout and NEVER consults _resolvedPay -> migrated amounts are
    ///         unreachable.
    function claimPayout() external {
        uint256 amount = _claimPayout(msg.sender);
        dividendToken.transfer(msg.sender, amount);
    }

    // ── test/inspection helpers (not part of the exploit path) ─────────────────
    function setPending(address holder, uint256 amount) external {
        _getHolderManagementStorage().pending[holder] = amount;
    }

    function pendingOf(address holder) external view returns (uint256) {
        return _getHolderManagementStorage().pending[holder];
    }

    function resolvedPayOf(address holder) external view returns (uint128) {
        return _getHolderManagementStorage()._resolvedPay[holder];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): claimPayout ALSO drains _resolvedPay for
// the caller, and _resolvePay ACCUMULATES (+=) so a second migration to the same
// newAddress no longer overwrites the first. This is the Cyfrin-verified fix:
// the resolved payout becomes claimable by the newAddress.
// ─────────────────────────────────────────────────────────────────────────────
contract DividendManagerFixed {
    event PaymentResolved(address indexed oldAddress, address indexed newAddress);

    struct HolderManagementStorage {
        mapping(address => uint128) _resolvedPay;
        mapping(address => uint256) pending;
    }

    HolderManagementStorage private _hms;

    MiniToken public dividendToken;

    constructor(address _dividendToken) {
        dividendToken = MiniToken(_dividendToken);
    }

    function _getHolderManagementStorage() private view returns (HolderManagementStorage storage) {
        return _hms;
    }

    function _claimPayout(address holder) internal returns (uint256) {
        HolderManagementStorage storage $ = _getHolderManagementStorage();
        uint256 amount = $.pending[holder];
        $.pending[holder] = 0;
        return amount;
    }

    function _resolvePay(address oldAddress, address newAddress) internal {
        // FIX: accumulate instead of overwrite.
        _getHolderManagementStorage()._resolvedPay[newAddress] += SafeCast.toUint128(_claimPayout(oldAddress));
        emit PaymentResolved(oldAddress, newAddress);
    }

    function resolveUser(address oldAddress, address newAddress) external {
        _resolvePay(oldAddress, newAddress);
    }

    function claimPayout() external {
        HolderManagementStorage storage $ = _getHolderManagementStorage();
        uint256 amount = _claimPayout(msg.sender);
        // FIX: the migrated payout is now claimable by the newAddress.
        uint256 resolved = $._resolvedPay[msg.sender];
        if (resolved != 0) {
            $._resolvedPay[msg.sender] = 0;
            amount += resolved;
        }
        dividendToken.transfer(msg.sender, amount);
    }

    function setPending(address holder, uint256 amount) external {
        _getHolderManagementStorage().pending[holder] = amount;
    }

    function pendingOf(address holder) external view returns (uint256) {
        return _getHolderManagementStorage().pending[holder];
    }

    function resolvedPayOf(address holder) external view returns (uint128) {
        return _getHolderManagementStorage()._resolvedPay[holder];
    }
}

/// @dev Stands in for the migrated-to investor account (newAddress). It can only
///      reach its dividends through the manager's public claimPayout().
contract Investor {
    function claim(address manager) external {
        DividendManager(manager).claimPayout();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: an investor loses access; their P pending dividend tokens are
// migrated to a new account, but the new account can never claim them. The P
// tokens (already held by the contract) are permanently locked. Harm magnitude
// is recorded on a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant OLD = 0x000000000000000000000000000000000000010D; // old (lost) account

    uint256 internal constant P = 1_000_000000; // 1,000 USDC (6 decimals) owed as pending payout

    // Exposed results for the driver.
    uint256 public pendingMigrated;    // P
    uint256 public newReceived;        // dividend tokens newAddress actually received (0)
    uint256 public contractLocked;     // dividend tokens still trapped in the manager (P)
    uint128 public resolvedPayForNew;  // _resolvedPay[newAddress] recorded but unclaimable (P)
    uint256 public sinkMarkerBalance;  // P (marker for measured harm)

    address public dmAddr;
    address public usdcAddr;
    address public markerAddr;
    address public newInvestorAddr;

    function run() external payable {
        // --- deploy the dividend token, the vulnerable manager, the investor,
        //     and (LAST) the harm marker ---
        MiniToken usdc = new MiniToken("USD Coin", "USDC", 6);              // nonce 1
        DividendManager dm = new DividendManager(address(usdc));           // nonce 2
        Investor investor = new Investor();                                // nonce 3
        MiniToken marker = new MiniToken("Locked USDC", "LOCKED-USDC", 6); // nonce 4 (LAST)

        dmAddr = address(dm);
        usdcAddr = address(usdc);
        markerAddr = address(marker);
        newInvestorAddr = address(investor);
        pendingMigrated = P;

        // --- OLD holder has P pending; the contract already holds those P tokens ---
        dm.setPending(OLD, P);
        usdc.mint(address(dm), P);

        // --- investor loses access: resolveUser migrates the payout to NEW ---
        //     _resolvePay settles OLD's pending and writes _resolvedPay[NEW]=P,
        //     transferring nothing.
        address NEW = address(investor);
        dm.resolveUser(OLD, NEW);

        resolvedPayForNew = dm.resolvedPayOf(NEW); // == P, recorded

        // --- NEW tries to claim through the ONLY available path ---
        uint256 before = usdc.balanceOf(NEW);
        investor.claim(address(dm)); // claimPayout(): pays NEW's own pending (0), ignores _resolvedPay
        newReceived = usdc.balanceOf(NEW) - before;

        // --- harm: NEW received nothing; the P tokens are trapped in the manager ---
        contractLocked = usdc.balanceOf(address(dm));

        require(resolvedPayForNew == uint128(P), "payout was recorded to _resolvedPay[new]");
        require(newReceived == 0, "new address could not claim the migrated payout");
        require(contractLocked == P, "P dividend tokens permanently locked in the manager");

        // --- record the locked magnitude on the marker to the SINK ---
        marker.mint(SINK, P);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
