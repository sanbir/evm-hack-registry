// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/*  Enjoyoors — userSupply stores the raw deposit, so rebase rewards stick
    (MixBytes, AuditVault 49876).
    SYNTHETIC, cheatcode-free. A 100 deposit is tracked as 100. The token
    then rebases 25 onto the vault. withdraw will not pay more than
    userSupply, so 25 stays in the vault forever. Share accounting pays 125. */

contract RebaseToken {
    mapping(address => uint256) public balanceOf;
    address public immutable minter;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function rebase(address holder, uint256 amount) external {
        balanceOf[holder] += amount;
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

contract Deposits {
    RebaseToken public token;
    mapping(address => mapping(address => uint256)) public userSupply;
    mapping(address => uint256) public totalSupply;

    constructor(RebaseToken token_) {
        token = token_;
    }

    function deposit(address token_, uint256 amount) external {
        require(token_ == address(token), "token");
        token.transferFrom(msg.sender, address(this), amount);
        totalSupply[token_] += amount;
        // @> VULN: userSupply[token][msg.sender] += amount ignores later rebases.
        userSupply[token_][msg.sender] += amount;
    }

    function withdraw(address token_, uint256 amount) external returns (uint256) {
        require(userSupply[token_][msg.sender] >= amount, "supply");
        userSupply[token_][msg.sender] -= amount;
        totalSupply[token_] -= amount;
        token.transfer(msg.sender, amount);
        return amount;
    }

    function withdrawShares(address token_) external returns (uint256 paid) {
        uint256 shares = userSupply[token_][msg.sender];
        uint256 all = totalSupply[token_];
        uint256 cash = token.balanceOf(address(this));
        paid = all == 0 ? 0 : shares * cash / all;
        userSupply[token_][msg.sender] = 0;
        totalSupply[token_] = all - shares;
        token.transfer(msg.sender, paid);
    }
}

contract Exploit {
    RebaseToken public token;
    Deposits public vault;
    uint256 public got;
    uint256 public stuck;
    uint256 public fair;

    constructor() {
        token = new RebaseToken();
        vault = new Deposits(token);
        token.mint(address(this), 100);
    }

    function run() external {
        vault.deposit(address(token), 100);
        require(vault.userSupply(address(token), address(this)) == 100, "tracked 100");
        token.rebase(address(vault), 25);
        require(token.balanceOf(address(vault)) == 125, "cash is 125");
        got = vault.withdraw(address(token), 100);
        stuck = token.balanceOf(address(vault));
        fair = 125;
        require(got == 100, "only the tracked deposit");
        require(stuck == 25, "rebase stuck");
        require(fair == got + stuck, "shares would pay 125");
        require(vault.userSupply(address(token), address(this)) == 0, "supply cleared");
    }
}
