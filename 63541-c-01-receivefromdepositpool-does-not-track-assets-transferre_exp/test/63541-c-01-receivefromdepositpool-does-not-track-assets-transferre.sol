// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Elytra finding 63541:
// "receiveFromDepositPool() does not track assets transferred".
//
// ElytraUnstakingVaultV1.receiveFromDepositPool(asset) is supposed to credit the
// assets the deposit pool just transferred into the unstaking vault. It tries to
// measure the transferred amount by comparing balanceBefore and balanceAfter —
// but both reads happen in the SAME call with NOTHING transferred between them,
// so `received` is ALWAYS 0. claimableAssets[asset] therefore never increases,
// even though real assets sit in the vault. Every user who requested a
// withdrawal can never claim: their assets are permanently locked in the vault.
//
// The receiveFromDepositPool body below is inlined VERBATIM from the finding.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Minimal ERC20 double for the opaque WHYPE asset the unstaking vault holds.
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
// VULNERABLE contract. receiveFromDepositPool is inlined VERBATIM from the
// finding; only surrounding scaffolding (modifier, storage, claim path) is
// minimal-but-faithful. The claim path can only pay what was credited to
// claimableAssets — exactly the invariant the bug violates.
// ─────────────────────────────────────────────────────────────────────────────
contract ElytraUnstakingVaultV1 {
    address public depositPool;
    mapping(address => uint256) public claimableAssets;

    event AssetsReceivedFromDepositPool(address indexed asset, uint256 amount);

    modifier onlyDepositPool() {
        require(msg.sender == depositPool, "not deposit pool");
        _;
    }

    constructor(address _depositPool) {
        depositPool = _depositPool;
    }

    function receiveFromDepositPool(address asset) external onlyDepositPool {
        // All assets are now ERC20 tokens (including WHYPE)
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        // Assets should be transferred before calling this function
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        uint256 received = balanceAfter - balanceBefore; // @> balanceBefore and balanceAfter are read with NO transfer between them, so received is ALWAYS 0
        claimableAssets[asset] += received;
        emit AssetsReceivedFromDepositPool(asset, received);
    }

    /// @notice Minimal faithful withdrawal-claim path: a user can only be paid
    ///         what has been credited to claimableAssets. Pays min(owed, balance).
    function claim(address asset, address to) external returns (uint256) {
        uint256 owed = claimableAssets[asset];
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 pay = owed < bal ? owed : bal;
        claimableAssets[asset] -= pay;
        IERC20(asset).transfer(to, pay);
        return pay;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: receiveFromDepositPool takes the explicit `amount` from the
// deposit pool and credits it directly (the recommendation in the finding).
// ─────────────────────────────────────────────────────────────────────────────
contract ElytraUnstakingVaultV1Fixed {
    address public depositPool;
    mapping(address => uint256) public claimableAssets;

    event AssetsReceivedFromDepositPool(address indexed asset, uint256 amount);

    modifier onlyDepositPool() {
        require(msg.sender == depositPool, "not deposit pool");
        _;
    }

    constructor(address _depositPool) {
        depositPool = _depositPool;
    }

    // FIX: accept an explicit amount and credit it directly, bypassing the
    // unreliable same-transaction balance comparison.
    function receiveFromDepositPool(address asset, uint256 amount) external onlyDepositPool {
        claimableAssets[asset] += amount;
        emit AssetsReceivedFromDepositPool(asset, amount);
    }

    function claim(address asset, address to) external returns (uint256) {
        uint256 owed = claimableAssets[asset];
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 pay = owed < bal ? owed : bal;
        claimableAssets[asset] -= pay;
        IERC20(asset).transfer(to, pay);
        return pay;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: deposit pool transfers 10e18 WHYPE into the unstaking vault
// and calls receiveFromDepositPool; claimableAssets stays 0, so the withdrawing
// user's claim pays 0 while the 10e18 stays locked in the vault. The locked
// magnitude is recorded on a LOCKED-WHYPE marker minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER = 0x00000000000000000000000000000000000055e2; // withdrawer

    uint256 internal constant AMOUNT = 10 ether;

    // Deployed contracts (Exploit is the deposit pool for both vaults).
    MiniToken public asset;
    ElytraUnstakingVaultV1 public vault;
    ElytraUnstakingVaultV1Fixed public fixedVault;
    MiniToken public asset2;
    MiniToken public marker;

    // Exposed results for the driver to assert on.
    uint256 public buggyClaimable;
    uint256 public buggyPaidToUser;
    uint256 public lockedInVault;
    uint256 public correctClaimable;
    uint256 public correctPaidToUser;
    uint256 public sinkMarkerBalance;

    constructor() {
        asset = new MiniToken("Wrapped HYPE", "WHYPE");                  // 0
        vault = new ElytraUnstakingVaultV1(address(this));              // 1  (Exploit == deposit pool)
        fixedVault = new ElytraUnstakingVaultV1Fixed(address(this));    // 2
        asset2 = new MiniToken("Wrapped HYPE", "WHYPE");               // 3  (control asset)
        marker = new MiniToken("Locked WHYPE", "LOCKED-WHYPE");        // 4  (marker, LAST)
    }

    function run() external payable {
        // ---------- BUGGY PATH ----------
        // Deposit pool transfers the user's withdrawal assets into the vault
        // (transferAssetToUnstakingVault), then tells the vault to track them.
        asset.mint(address(vault), AMOUNT);
        vault.receiveFromDepositPool(address(asset));

        // Bug: claimableAssets stays 0 despite 10e18 sitting in the vault.
        buggyClaimable = vault.claimableAssets(address(asset));

        // The user who requested the withdrawal tries to claim -> receives 0.
        buggyPaidToUser = vault.claim(address(asset), USER);

        // The 10e18 is permanently locked in the vault (unreachable by anyone).
        lockedInVault = asset.balanceOf(address(vault));

        require(buggyClaimable == 0, "claimable must stay 0 under the bug");
        require(buggyPaidToUser == 0, "user must be paid 0 under the bug");
        require(lockedInVault == AMOUNT, "assets must be locked in the vault");

        // ---------- CONTROL: fixed variant credits and pays out ----------
        asset2.mint(address(fixedVault), AMOUNT);
        fixedVault.receiveFromDepositPool(address(asset2), AMOUNT);
        correctClaimable = fixedVault.claimableAssets(address(asset2));
        correctPaidToUser = fixedVault.claim(address(asset2), USER);
        require(correctClaimable == AMOUNT, "fixed must credit the full amount");
        require(correctPaidToUser == AMOUNT, "fixed must pay the full amount");

        // ---------- record harm (measured asset left at the SINK) ----------
        marker.mint(SINK, AMOUNT);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
