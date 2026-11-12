// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Roots Staker — IGauge.getReward(address) does not match RewardVault's
    getReward(address,address) (Pashov, February 2025, C-01).
    SYNTHETIC, cheatcode-free. The blamed call is verbatim (@> VULN).

    withdraw calls _fetchRewards, which calls the one-argument selector.
    RewardVault has no such function, so the call reverts and 5 collateral
    stays in the staker. The two-argument selector pays the user the 5. */

contract Collateral {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IGauge {
    function getReward(address account) external returns (uint256);
}

interface IRewardVault {
    function getReward(address account, address recipient) external returns (uint256);
}

contract RewardVault {
    Collateral public token;
    uint256 public constant REWARD = 5 ether;

    constructor(Collateral _token) {
        token = _token;
    }

    function getReward(address, address recipient) external returns (uint256) {
        token.transfer(recipient, REWARD);
        return REWARD;
    }
}

contract Staker {
    Collateral public token;
    IGauge public gauge;
    uint256 public locked;

    constructor(Collateral _token, IGauge _gauge) {
        token = _token;
        gauge = _gauge;
    }

    function deposit(uint256 amount) external {
        locked += amount;
    }

    function _fetchRewards() internal {
        // @> VULN: RewardVault.getReward takes (account, recipient). This selector does not exist.
        gauge.getReward(address(this));
    }

    function withdraw(address to) external {
        _fetchRewards();
        uint256 amount = locked;
        locked = 0;
        token.transfer(to, amount);
    }

    function withdrawFixed(address to) external {
        IRewardVault(address(gauge)).getReward(address(this), to);
        uint256 amount = locked;
        locked = 0;
        token.transfer(to, amount);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 5 ether;

    Collateral public token; // nonce 1
    RewardVault public vault; // nonce 2
    Staker public staker; // nonce 3
    uint256 public stuck;
    uint256 public paid;
    bool public withdrew;

    constructor() {
        token = new Collateral();
        vault = new RewardVault(token);
        staker = new Staker(token, IGauge(address(vault)));
    }

    function run() external {
        token.mint(address(staker), AMOUNT);
        token.mint(address(vault), AMOUNT);
        staker.deposit(AMOUNT);
        try staker.withdraw(msg.sender) {
            withdrew = true;
        } catch {
            withdrew = false;
        }
        stuck = token.balanceOf(address(staker));
        paid = token.balanceOf(msg.sender);
        require(withdrew == false, "withdraw should revert");
        require(stuck == AMOUNT, "5 did not stay in the staker");
        require(paid == 0, "user was paid");
    }
}
