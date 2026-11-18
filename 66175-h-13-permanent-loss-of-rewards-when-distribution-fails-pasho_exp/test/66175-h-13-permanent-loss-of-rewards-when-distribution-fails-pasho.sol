// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum RAACMinter — failed distribution drops rewards (Pashov H-13, finding 66175)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _processMintedRewards zeros excessTokens, then copies poolInfo into memory.
    A reverting receiver discards that memory, so the tokens stay in the minter with no
    pendingRewards balance to retry. Blamed lines preserved verbatim below (@> VULN). */

contract RaacToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IRAACMinterRewardsReceiver {
    function deposit(uint256 amount) external;
}

contract RewardsReceiver {
    RaacToken public token;
    bool public fail;
    uint256 public received;

    constructor(RaacToken _token, bool _fail) {
        token = _token;
        fail = _fail;
    }

    function setFail(bool next) external {
        fail = next;
    }

    function deposit(uint256 amount) external {
        bool reject = fail;
        if (reject) revert("distribution failed");
        token.transferFrom(msg.sender, address(this), amount);
        received += amount;
    }
}

contract RAACMinter {
    struct DistributionPool {
        address pool;
        uint256 weight;
        uint256 pendingRewards;
    }

    RaacToken public token;
    uint256 public excessTokens;
    uint256 public totalWeight;
    address[] public distributionPools;
    mapping(address => DistributionPool) public poolInfo;
    bool public persistFailed;
    event DistributionFailed(address pool, uint256 amount);

    constructor(RaacToken _token, address poolA, uint256 weightA, address poolB, uint256 weightB, bool _persist) {
        token = _token;
        persistFailed = _persist;
        distributionPools.push(poolA);
        distributionPools.push(poolB);
        poolInfo[poolA] = DistributionPool(poolA, weightA, 0);
        poolInfo[poolB] = DistributionPool(poolB, weightB, 0);
        totalWeight = weightA + weightB;
    }

    function pendingOf(address pool) external view returns (uint256) {
        return poolInfo[pool].pendingRewards;
    }

    function fundExcess(uint256 amount) external {
        excessTokens = amount;
    }

    function _processMintedRewards() internal {
        uint256 rewardPerWeight = excessTokens / totalWeight;
        excessTokens = 0; // cleared before any receiver accepts the tokens
        for (uint256 i = 0; i < distributionPools.length; i++) {
            address pool = distributionPools[i];
            if (!persistFailed) {
                DistributionPool memory poolData = poolInfo[pool];
                poolData.pendingRewards += rewardPerWeight * poolData.weight; // @> VULN: pendingRewards is added on a memory copy and discarded if deposit reverts
                _depositPendingReward(poolData);
                // FIX: read poolInfo into storage so the catch keeps pendingRewards for a retry
            } else {
                DistributionPool storage stored = poolInfo[pool];
                stored.pendingRewards += rewardPerWeight * stored.weight;
                if (_depositPendingReward(stored)) stored.pendingRewards = 0;
            }
        }
    }

    function _depositPendingReward(DistributionPool memory poolData) internal returns (bool paid) {
        token.approve(poolData.pool, poolData.pendingRewards);
        try IRAACMinterRewardsReceiver(poolData.pool).deposit(poolData.pendingRewards) {
            poolData.pendingRewards = 0;
            paid = true;
        } catch {
            emit DistributionFailed(poolData.pool, poolData.pendingRewards);
            // 400 tokens are now permanently lost as excessTokens = 0 and pendingRewards is only in memory
            paid = false;
        }
    }

    function process() external {
        _processMintedRewards();
    }

    /// @dev Control path. Pays a pending balance that was kept in storage. Not called from run().
    function flush(address pool) external {
        DistributionPool storage stored = poolInfo[pool];
        uint256 amount = stored.pendingRewards;
        token.approve(pool, amount);
        IRAACMinterRewardsReceiver(pool).deposit(amount);
        stored.pendingRewards = 0;
    }
}

contract Exploit {
    RaacToken public token; // CREATE nonce 1
    RewardsReceiver public poolA; // CREATE nonce 2
    RewardsReceiver public poolB; // CREATE nonce 3
    RAACMinter public minter; // CREATE nonce 4
    uint256 public stuck;

    constructor() {
        token = new RaacToken();
        poolA = new RewardsReceiver(token, true);
        poolB = new RewardsReceiver(token, false);
        minter = new RAACMinter(token, address(poolA), 2, address(poolB), 3, false);
    }

    function findingTag() public pure returns (string memory) {
        return "66175";
    }

    function run() external {
        require(keccak256(bytes(findingTag())) == keccak256("66175"), "finding");
        token.mint(address(minter), 1000);
        minter.fundExcess(1000);
        minter.process();
        stuck = token.balanceOf(address(minter));
        require(poolA.received() == 0, "pool A paid");
        require(poolB.received() == 600, "pool B");
        require(stuck == 400, "400 stuck");
        require(minter.excessTokens() == 0, "excess cleared");
        require(minter.pendingOf(address(poolA)) == 0, "no retry balance");
    }
}
