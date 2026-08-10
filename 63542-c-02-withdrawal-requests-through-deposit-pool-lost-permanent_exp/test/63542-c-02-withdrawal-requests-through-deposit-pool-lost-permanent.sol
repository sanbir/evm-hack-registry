// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Elytra finding 63542 (C-02):
// "Withdrawal requests through deposit pool lost permanently".
//
// A user withdraws by calling ElytraDepositPoolV1.requestWithdrawal(). The pool
// pulls the user's elyAsset (receipt token), approves the unstaking vault, and
// forwards the request to ElytraUnstakingVaultV1.requestWithdrawal(). But the
// vault records `user: msg.sender` — and msg.sender is the DEPOSIT POOL, not the
// real user. The user's elyAsset is consumed (burned) on request, yet the
// withdrawal request is owned by the pool contract. When the real user calls
// completeWithdrawal(), it reverts (`msg.sender != request.user`), so the user's
// underlying assets are permanently locked in the vault and unrecoverable.
//
// Both vulnerable lines are embedded VERBATIM from the finding:
//   1. ElytraDepositPoolV1.requestWithdrawal  (forwards as msg.sender = pool)
//   2. ElytraUnstakingVaultV1: withdrawalRequests[id] = WithdrawalRequest({user: msg.sender,...})
// completeWithdrawal is reconstructed from the report's stated revert condition
// (msg.sender != request.user). MockERC20 is a minimal faithful double for the
// opaque token boundary (elyAsset + underlying).
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// @dev Minimal faithful double for OpenZeppelin's SafeERC20 (the pool uses it).
library SafeERC20 {
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        require(token.transferFrom(from, to, value), "SafeERC20: transferFrom failed");
    }

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(token.transfer(to, value), "SafeERC20: transfer failed");
    }
}

/// @dev Minimal ERC20 double for elyAsset (receipt token) and the underlying asset.
contract MockERC20 {
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

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
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

/// @dev Faithful minimal double for the Elytra config registry.
library ElytraConstants {
    bytes32 internal constant ELYTRA_UNSTAKING_VAULT = keccak256("ELYTRA_UNSTAKING_VAULT");
}

interface IElytraConfig {
    function getContract(bytes32 key) external view returns (address);
    function getElyAsset() external view returns (address);
}

contract ElytraConfig is IElytraConfig {
    address public elyAsset;
    mapping(bytes32 => address) public contracts;

    function setElyAsset(address a) external {
        elyAsset = a;
    }

    function setContract(bytes32 key, address v) external {
        contracts[key] = v;
    }

    function getElyAsset() external view returns (address) {
        return elyAsset;
    }

    function getContract(bytes32 key) external view returns (address) {
        return contracts[key];
    }
}

interface IElytraUnstakingVault {
    function requestWithdrawal(address asset, uint256 elyAssetAmount) external returns (uint256 requestId);
}

interface IElytraUnstakingVaultFixed {
    function requestWithdrawalForUser(
        address user,
        address asset,
        uint256 elyAssetAmount
    ) external returns (uint256 requestId);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE unstaking vault: records `user: msg.sender` — the deposit pool.
// ─────────────────────────────────────────────────────────────────────────────
contract ElytraUnstakingVaultV1 {
    struct WithdrawalRequest {
        address user;
        address asset;
        uint256 elyAssetAmount;
        uint256 assetAmount;
        uint256 requestTime;
        bool completed;
    }

    IERC20 public elyAsset;
    IERC20 public underlying;
    uint256 public nextRequestId;
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;

    constructor(address _elyAsset, address _underlying) {
        elyAsset = IERC20(_elyAsset);
        underlying = IERC20(_underlying);
    }

    function requestWithdrawal(address asset, uint256 elyAssetAmount) external returns (uint256 requestId) {
        // Pull the pool-approved elyAsset and burn it (the user's receipt token is consumed).
        elyAsset.transferFrom(msg.sender, address(this), elyAssetAmount);
        MockERC20(address(elyAsset)).burn(address(this), elyAssetAmount);

        uint256 assetAmount = elyAssetAmount; // 1:1 redemption for the reproduction

        requestId = nextRequestId++;

        // ─── VERBATIM vulnerable assignment from the finding ───
        withdrawalRequests[requestId] = WithdrawalRequest({
            user: msg.sender, // @> records the CALLER (deposit pool), not the real user -> user can never complete
            asset: asset,
            elyAssetAmount: elyAssetAmount,
            assetAmount: assetAmount,
            requestTime: block.timestamp,
            completed: false
        });
    }

    // Reconstructed from the report's stated revert condition (msg.sender != request.user).
    function completeWithdrawal(uint256 requestId) external returns (uint256) {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        require(msg.sender == request.user, "not request owner");
        require(!request.completed, "already completed");
        request.completed = true;
        underlying.transfer(request.user, request.assetAmount);
        return request.assetAmount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE deposit pool: forwards the request as msg.sender = pool.
// ElytraDepositPoolV1.requestWithdrawal body is inlined VERBATIM from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract ElytraDepositPoolV1 {
    using SafeERC20 for IERC20;

    IElytraConfig public elytraConfig;

    // minimal ReentrancyGuard
    uint256 private _reentrancyStatus = 1;

    modifier nonReentrant() {
        require(_reentrancyStatus == 1, "reentrant");
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    // minimal Pausable
    bool public paused;

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    // supported-asset gate
    mapping(address => bool) public supportedAssets;

    modifier onlySupportedAsset(address asset) {
        require(supportedAssets[asset], "unsupported asset");
        _;
    }

    constructor(address config) {
        elytraConfig = IElytraConfig(config);
    }

    function setSupportedAsset(address asset, bool s) external {
        supportedAssets[asset] = s;
    }

    function requestWithdrawal(
        address asset,
        uint256 elyAssetAmount
    )
        external
        nonReentrant
        whenNotPaused
        onlySupportedAsset(asset)
        returns (uint256 requestId)
    {
        address unstakingVault = elytraConfig.getContract(ElytraConstants.ELYTRA_UNSTAKING_VAULT);

        // Transfer elyAsset tokens to this contract for burning
        address elyAssetToken = elytraConfig.getElyAsset();
        IERC20(elyAssetToken).safeTransferFrom(msg.sender, address(this), elyAssetAmount);

        // Approve unstaking vault to burn tokens
        IERC20(elyAssetToken).approve(unstakingVault, elyAssetAmount);

        // Request withdrawal through unstaking vault
        // @> forwards with msg.sender = this pool, so the vault records the POOL as owner, not the user
        requestId = IElytraUnstakingVault(unstakingVault).requestWithdrawal(asset, elyAssetAmount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED variants (negative control): a requestWithdrawalForUser() that records
// the real user, so completeWithdrawal() succeeds and returns the assets.
// ─────────────────────────────────────────────────────────────────────────────
contract ElytraUnstakingVaultV1Fixed {
    struct WithdrawalRequest {
        address user;
        address asset;
        uint256 elyAssetAmount;
        uint256 assetAmount;
        uint256 requestTime;
        bool completed;
    }

    IERC20 public elyAsset;
    IERC20 public underlying;
    uint256 public nextRequestId;
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;

    constructor(address _elyAsset, address _underlying) {
        elyAsset = IERC20(_elyAsset);
        underlying = IERC20(_underlying);
    }

    // FIX: only the pool calls this and passes the REAL user as the owner.
    function requestWithdrawalForUser(
        address user,
        address asset,
        uint256 elyAssetAmount
    ) external returns (uint256 requestId) {
        elyAsset.transferFrom(msg.sender, address(this), elyAssetAmount);
        MockERC20(address(elyAsset)).burn(address(this), elyAssetAmount);

        uint256 assetAmount = elyAssetAmount;

        requestId = nextRequestId++;

        withdrawalRequests[requestId] = WithdrawalRequest({
            user: user, // FIX: record the real user
            asset: asset,
            elyAssetAmount: elyAssetAmount,
            assetAmount: assetAmount,
            requestTime: block.timestamp,
            completed: false
        });
    }

    function completeWithdrawal(uint256 requestId) external returns (uint256) {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        require(msg.sender == request.user, "not request owner");
        require(!request.completed, "already completed");
        request.completed = true;
        underlying.transfer(request.user, request.assetAmount);
        return request.assetAmount;
    }
}

contract ElytraDepositPoolV1Fixed {
    using SafeERC20 for IERC20;

    IElytraConfig public elytraConfig;
    mapping(address => bool) public supportedAssets;

    modifier onlySupportedAsset(address asset) {
        require(supportedAssets[asset], "unsupported asset");
        _;
    }

    constructor(address config) {
        elytraConfig = IElytraConfig(config);
    }

    function setSupportedAsset(address asset, bool s) external {
        supportedAssets[asset] = s;
    }

    function requestWithdrawal(
        address asset,
        uint256 elyAssetAmount
    ) external onlySupportedAsset(asset) returns (uint256 requestId) {
        address unstakingVault = elytraConfig.getContract(ElytraConstants.ELYTRA_UNSTAKING_VAULT);
        address elyAssetToken = elytraConfig.getElyAsset();
        IERC20(elyAssetToken).safeTransferFrom(msg.sender, address(this), elyAssetAmount);
        IERC20(elyAssetToken).approve(unstakingVault, elyAssetAmount);
        // FIX: pass the real user (msg.sender) through to the vault as the owner.
        requestId = IElytraUnstakingVaultFixed(unstakingVault).requestWithdrawalForUser(
            msg.sender,
            asset,
            elyAssetAmount
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: acts as the real user. Requests a withdrawal through the pool,
// then shows the request is owned by the pool and the user's completeWithdrawal
// reverts permanently, locking 6e18 underlying HYPE in the vault. The locked
// magnitude is recorded on a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant WITHDRAW_AMOUNT = 6 ether;

    // Exposed results.
    address public poolAddr;
    address public vaultAddr;
    address public markerAddr;
    address public recordedRequestUser;
    bool public userCompleteReverted;
    uint256 public lockedInVault;
    uint256 public sinkMarkerBalance;

    function run() external payable {
        // --- create every contract unconditionally, fixed order (marker LAST) ---
        MockERC20 ely = new MockERC20("Elytra HYPE", "elyHYPE");           // nonce 1
        MockERC20 hype = new MockERC20("Hyperliquid", "HYPE");             // nonce 2
        ElytraConfig config = new ElytraConfig();                          // nonce 3
        ElytraUnstakingVaultV1 vault = new ElytraUnstakingVaultV1(address(ely), address(hype)); // nonce 4
        ElytraDepositPoolV1 pool = new ElytraDepositPoolV1(address(config)); // nonce 5
        MockERC20 marker = new MockERC20("Locked HYPE", "LOCKED-HYPE");     // nonce 6 (LAST)

        poolAddr = address(pool);
        vaultAddr = address(vault);
        markerAddr = address(marker);

        // --- wire the config registry + supported asset ---
        config.setElyAsset(address(ely));
        config.setContract(ElytraConstants.ELYTRA_UNSTAKING_VAULT, address(vault));
        pool.setSupportedAsset(address(hype), true);

        // --- pre-fund the vault with underlying so a CORRECT withdrawal could be paid ---
        hype.mint(address(vault), WITHDRAW_AMOUNT);

        // --- the user (this Exploit) holds elyAsset and approves the pool ---
        ely.mint(address(this), WITHDRAW_AMOUNT);
        ely.approve(address(pool), WITHDRAW_AMOUNT);

        // --- user requests withdrawal via the deposit pool (the real, buggy path) ---
        uint256 requestId = pool.requestWithdrawal(address(hype), WITHDRAW_AMOUNT);

        // --- the vault recorded the POOL as the owner, not the user ---
        (address recordedUser,,,,,) = vault.withdrawalRequests(requestId);
        recordedRequestUser = recordedUser;

        // --- the real user (this contract) tries to complete -> reverts permanently ---
        try vault.completeWithdrawal(requestId) returns (uint256) {
            userCompleteReverted = false;
        } catch {
            userCompleteReverted = true;
        }

        // --- underlying is now stuck in the vault, unrecoverable by the user ---
        lockedInVault = hype.balanceOf(address(vault));

        // --- harm holds: request owned by pool AND user cannot complete AND funds stuck ---
        require(recordedUser == address(pool), "request not owned by pool");
        require(userCompleteReverted, "user unexpectedly completed");
        require(lockedInVault == WITHDRAW_AMOUNT, "funds not locked");

        // --- record the locked magnitude on the marker to the SINK ---
        marker.mint(SINK, WITHDRAW_AMOUNT);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
