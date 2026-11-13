// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cedro LiquidationManager — discount stays 0 when currentLTV >= 1e18
    (Zokyo, March 2024).

    currentLTV is 1.2e18. The branch that sets
    discount = 1e36 / currentLTV - 0.999e18 is skipped, so discount is 0.
    Seized collateral is the 1000 debt with no bonus. The max discount of
    10 percent would seize 1100. The unpaid bonus is 100.

    The control applies liqMaxDiscount when LTV is at least 1e18 and seizes
    1100. run() does not warp. */

contract Collateral {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

struct LiqConfig {
    uint256 liqMaxDiscount;
}

contract LiquidationManager {
    uint256 public constant WAD = 1e18;
    Collateral public collateral;
    LiqConfig public config;
    uint256 public lastDiscount;
    uint256 public lastSeized;

    constructor(Collateral collateral_, uint256 maxDiscount) {
        collateral = collateral_;
        config.liqMaxDiscount = maxDiscount;
    }

    function liquidate(uint256 currentLTV, uint256 debt, address liquidator) external virtual returns (uint256 seized) {
        uint256 discount;
        if (currentLTV < WAD) {
            discount = 1e36 / currentLTV - 999000000000000000;
            if (discount > config.liqMaxDiscount) {
                discount = config.liqMaxDiscount;
            }
        }
        // @> VULN: currentLTV >= 1e18 leaves discount at 0, so the bonus is not paid
        lastDiscount = discount;
        seized = debt * (WAD + discount) / WAD;
        lastSeized = seized;
        collateral.transfer(liquidator, seized);
    }
}

contract LiquidationManagerFixed is LiquidationManager {
    constructor(Collateral collateral_, uint256 maxDiscount) LiquidationManager(collateral_, maxDiscount) {}

    function liquidate(uint256 currentLTV, uint256 debt, address liquidator) external override returns (uint256 seized) {
        uint256 discount;
        if (currentLTV < WAD) {
            discount = 1e36 / currentLTV - 999000000000000000;
            if (discount > config.liqMaxDiscount) discount = config.liqMaxDiscount;
        } else {
            discount = config.liqMaxDiscount;
        }
        lastDiscount = discount;
        seized = debt * (WAD + discount) / WAD;
        lastSeized = seized;
        collateral.transfer(liquidator, seized);
    }
}

contract Exploit {
    uint256 public constant LTV = 1.2 ether;
    uint256 public constant DEBT = 1000 ether;
    uint256 public constant SEIZED = 1000 ether;
    uint256 public constant FAIR_SEIZED = 1100 ether;
    uint256 public constant BONUS = 100 ether;

    Collateral public collateral;
    LiquidationManager public manager;
    uint256 public seized;
    uint256 public discount;

    constructor() {
        collateral = new Collateral();
        manager = new LiquidationManager(collateral, 0.1 ether);
        collateral.mint(address(manager), 2000 ether);
    }

    function run() external {
        seized = manager.liquidate(LTV, DEBT, address(this));
        discount = manager.lastDiscount();
        require(discount == 0, "discount");
        require(seized == SEIZED, "seized");
        require(FAIR_SEIZED - seized == BONUS, "bonus");
        require(collateral.balanceOf(address(this)) == SEIZED, "balance");
    }
}
