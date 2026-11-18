// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum DebtToken — totalSupply rayMuls interest that was already minted
    (Pashov, 2025-05-06, H-03, finding 66165).
    SYNTHETIC, cheatcode-free. mint adds scaledBalanceIncrease into the scaled
    supply, then totalSupply multiplies that supply by the usage index again.
    A 300-token borrow cap rejects the next 40-token borrow while true debt is 250. */

contract LendingPool {
    uint256 internal constant RAY = 1e27;
    uint256 public constant BORROW_CAP = 300e18;

    IDebt public debt;
    uint256 public index = RAY;
    uint256 public actualDebt;

    function bind(IDebt _debt) external {
        debt = _debt;
    }

    function getNormalizedDebt() external view returns (uint256) {
        return index;
    }

    function accrue() external {
        actualDebt *= 2;
        index *= 2;
    }

    function borrow(address user, uint256 amount) external returns (bool) {
        uint256 supply = debt.totalSupply();
        if (supply + amount > BORROW_CAP) return false;
        debt.mint(user, amount, index);
        actualDebt += amount;
        return true;
    }
}

interface IDebt {
    function mint(address onBehalfOf, uint256 amount, uint256 poolUsageIndex) external;
    function totalSupply() external view returns (uint256);
}

contract DebtToken is IDebt {
    uint256 internal constant RAY = 1e27;

    LendingPool public pool;
    mapping(address => uint256) public scaledBalance;
    mapping(address => uint256) public positionIndex;
    uint256 public scaledSupply;

    constructor(LendingPool _pool) {
        pool = _pool;
    }

    function rayMul(uint256 a, uint256 b) public pure returns (uint256) {
        return (a * b + RAY / 2) / RAY;
    }

    function rayDiv(uint256 a, uint256 b) public pure returns (uint256) {
        return (a * RAY + b / 2) / b;
    }

    function totalSupply() public view returns (uint256) {
        return rayMul(scaledSupply, pool.getNormalizedDebt());
    }

    function mint(address onBehalfOf, uint256 amount, uint256 poolUsageIndex) external {
        require(msg.sender == address(pool), "pool");
        uint256 amountScaled = rayDiv(amount, poolUsageIndex);
        uint256 rawDebtBalance = scaledBalance[onBehalfOf];
        uint256 storedIndex = positionIndex[onBehalfOf];
        uint256 scaledBalanceIncrease;
        if (storedIndex != 0 && storedIndex < poolUsageIndex) {
            scaledBalanceIncrease = rayMul(rawDebtBalance, poolUsageIndex) - rayMul(rawDebtBalance, storedIndex);
        }
        uint256 amountToMint = amountScaled + scaledBalanceIncrease; // @> VULN: interest already scaled by the index is added to the scaled supply, and totalSupply rayMuls it again
        scaledBalance[onBehalfOf] += amountToMint;
        scaledSupply += amountToMint;
        positionIndex[onBehalfOf] = poolUsageIndex;
    }
}

contract DebtTokenFixed is IDebt {
    uint256 internal constant RAY = 1e27;

    LendingPool public pool;
    mapping(address => uint256) public scaledBalance;
    uint256 public scaledSupply;

    constructor(LendingPool _pool) {
        pool = _pool;
    }

    function rayMul(uint256 a, uint256 b) public pure returns (uint256) {
        return (a * b + RAY / 2) / RAY;
    }

    function rayDiv(uint256 a, uint256 b) public pure returns (uint256) {
        return (a * RAY + b / 2) / b;
    }

    function totalSupply() public view returns (uint256) {
        return rayMul(scaledSupply, pool.getNormalizedDebt());
    }

    function mint(address onBehalfOf, uint256 amount, uint256 poolUsageIndex) external {
        require(msg.sender == address(pool), "pool");
        uint256 amountScaled = rayDiv(amount, poolUsageIndex);
        scaledBalance[onBehalfOf] += amountScaled;
        scaledSupply += amountScaled;
        poolUsageIndex;
    }
}

contract Exploit {
    LendingPool public pool;
    DebtToken public debt;

    address public constant ALICE = address(0xA11CE);
    address public constant BOB = address(0xB0B);

    uint256 public inflated;
    uint256 public trueDebt;
    bool public bobBlocked;

    constructor() {
        pool = new LendingPool();
        debt = new DebtToken(pool);
        pool.bind(debt);
    }

    function run() external {
        require(pool.borrow(ALICE, 100e18), "first");
        pool.accrue();
        require(pool.borrow(ALICE, 50e18), "second");

        inflated = debt.totalSupply();
        trueDebt = pool.actualDebt();
        bobBlocked = !pool.borrow(BOB, 40e18);

        require(inflated == 450e18, "supply");
        require(trueDebt == 250e18, "true debt");
        require(bobBlocked, "bob was allowed to borrow");
        require(trueDebt + 40e18 <= pool.BORROW_CAP(), "true debt is under the cap");
        require(inflated > pool.BORROW_CAP(), "inflated supply is under the cap");
    }
}
