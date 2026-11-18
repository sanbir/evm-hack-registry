// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Eggs — repay computes newBorrow and then does not store it (Cantina, February 2025).
    The quoted line is `Loans[msg.sender].borrowed - newBorrow;`.
    A borrower who sends 40 SONIC against a 100 SONIC debt still owes 100.
    The 40 SONIC is taken. The fixed line assigns borrowed = newBorrow, leaving 60. */

contract Sonic {
    string public symbol = "SONIC";
    uint8 public constant decimals = 18;
    address public minter;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
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

contract Eggs {
    struct Loan {
        uint256 borrowed;
    }

    Sonic public sonic;
    mapping(address => Loan) public loans;
    uint256 public discarded;

    constructor(Sonic _sonic) {
        sonic = _sonic;
    }

    function borrow(uint256 amount) external {
        loans[msg.sender].borrowed = amount;
        sonic.transfer(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        sonic.transferFrom(msg.sender, address(this), amount);
        uint256 borrowed = loans[msg.sender].borrowed;
        uint256 newBorrow = borrowed - amount;
        discarded = loans[msg.sender].borrowed - newBorrow; // @> VULN: not assigned back to loans[msg.sender].borrowed
    }
}

contract EggsFixed {
    struct Loan {
        uint256 borrowed;
    }

    Sonic public sonic;
    mapping(address => Loan) public loans;

    constructor(Sonic _sonic) {
        sonic = _sonic;
    }

    function borrow(uint256 amount) external {
        loans[msg.sender].borrowed = amount;
        sonic.transfer(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        sonic.transferFrom(msg.sender, address(this), amount);
        uint256 borrowed = loans[msg.sender].borrowed;
        uint256 newBorrow = borrowed - amount;
        loans[msg.sender].borrowed = newBorrow;
    }
}

contract Exploit {
    Sonic public sonic; // nonce 1
    Eggs public eggs; // nonce 2

    constructor() {
        sonic = new Sonic();
        eggs = new Eggs(sonic);
    }

    function run() external {
        sonic.mint(address(eggs), 100 ether);
        eggs.borrow(100 ether);
        uint256 debt = eggs.loans(address(this));
        require(debt == 100 ether, "borrowed 100");
        require(sonic.balanceOf(address(this)) == 100 ether, "received 100");
        sonic.approve(address(eggs), 40 ether);
        eggs.repay(40 ether);
        debt = eggs.loans(address(this));
        require(debt == 100 ether, "debt unchanged");
        require(eggs.discarded() == 40 ether, "discarded 40");
        require(sonic.balanceOf(address(eggs)) == 40 ether, "40 taken");
        require(sonic.balanceOf(address(this)) == 60 ether, "borrower left 60");
    }
}
